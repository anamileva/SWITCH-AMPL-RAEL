#!/bin/bash

function print_help {
  echo $0 # The name of this file. 
  cat <<END_HELP
import_results_to_mysql.sh
SYNOPSIS
	./import_results_to_mysql.sh -h 127.0.0.1 -P 3307 # For connecting through an ssh tunnel
	./import_results_to_mysql.sh                      # For connecting to the DB directly
INPUTS
 --help                   Print this message
 -n | --no-tunnel         Do not try to initiate an ssh tunnel to connect to the database. Overrides default behavior. 
  -u [DB Username]
  -p [DB Password]
  -D [DB name]
  -P/--port [port number]
  -h [DB server]
  --ExportOnly             Only export summaries of the results, don't import or crunch data in the DB
All arguments are optional.
END_HELP
}

##########################
# Default values
read SCENARIO_ID < scenario_id.txt
DB_name='switch_results_wecc_v2_2'
db_server='switch-db2.erg.berkeley.edu'
port=3306
ssh_tunnel=1
results_dir="results"
results_graphing_dir="results_for_graphing"

# Set the umask to give group read & write permissions to all files & directories made by this script.
umask 0002

###################################################
# Detect optional command-line arguments
ExportOnly=0
while [ -n "$1" ]; do
case $1 in
  -n | --no-tunnel)
    ssh_tunnel=0; shift 1 ;;
  -u)
    user=$2; shift 2 ;;
  -p)
    password=$2; shift 2 ;;
  -P | --port)
    port=$2; shift 2 ;;
  -D)
    DB_name=$2; shift 2 ;;
  -h)
    db_server=$2; shift 2 ;;
  --ExportOnly) 
    ExportOnly=1; shift 1 ;;
  --help)
    print_help; exit 0 ;;
  *)
    echo "Unknown option $1"; print_help; exit 1 ;;
esac
done


##########################
# Get the user name and password 
# Note that passing the password to mysql via a command line parameter is considered insecure
# http://dev.mysql.com/doc/refman/5.0/en/password-security.html
default_user=$(whoami)
if [ ! -n "$user" ]
then 
	printf "User name for MySQL $DB_name on $db_server [$default_user]? "
	read user
	if [ -z "$user" ]; then 
	  user="$default_user"
	fi
fi
if [ ! -n "$password" ]
then 
  echo "Password for MySQL $DB_name on $db_server? "
  stty_orig=`stty -g`   # Save screen settings
  stty -echo            # To keep the password vaguely secure, don't let it show to the screen
  read password
  stty $stty_orig       # Restore screen settings
	echo " "
fi

function clean_up {
  [ $ssh_tunnel -eq 1 ] && kill -9 $ssh_pid # This ensures that the ssh tunnel will be taken down if the program exits abnormally
  unset password
}

function is_port_free {
  target_port=$1
  if [ $(netstat -ant | \
         sed -e '/^tcp/ !d' -e 's/^[^ ]* *[^ ]* *[^ ]* *.*[\.:]\([0-9]*\) .*$/\1/' | \
         sort -g | uniq | \
         grep $target_port | wc -l) -eq 0 ]; then
    return 1
  else
    return 0
  fi
}

#############
# Try starting an ssh tunnel if requested
if [ $ssh_tunnel -eq 1 ]; then 
  echo "Trying to open an ssh tunnel. If it prompts you for your password, this method won't work."
  local_port=3307
  is_port_free $local_port
  while [ $? -eq 0 ]; do
    local_port=$((local_port+1))
    is_port_free $local_port
  done
  ssh -N -p 22 -c 3des "$user"@"$db_server" -L $local_port/127.0.0.1/$port &
  ssh_pid=$!
  sleep 1
  connection_string="-h 127.0.0.1 --port $local_port --local-infile=1 -u $user -p$password $DB_name"
  trap "clean_up;" EXIT INT TERM 
else
  connection_string="-h $db_server --port $port --local-infile=1 -u $user -p$password $DB_name"
fi

test_connection=`mysql $connection_string --column-names=false -e "show tables;"`
if [ -z "$test_connection" ]
then
  connection_string=`echo "$connection_string" | sed -e "s/ -p[^ ]* / -pXXX /"`
  echo "Could not connect to database with settings: $connection_string"
  exit 0
fi

###################################################
# Import all of the results files into the DB
if [ $ExportOnly = 0 ]; then

# First clear out the prior instance of this run
# You can do this manually with this SQL command: call clear_scenario_results(SCENARIO_ID);
  echo "Flushing Prior results for scenario ${SCENARIO_ID}"
  mysql $connection_string --column-names=false -e "call clear_scenario_results(${SCENARIO_ID});"

  echo 'Importing results files...'
  ###################################################
  # import a summary of run times for various processes
  # To do: add time for database export, storing results, compiling, etc.
  echo 'Importing run times...'
  printf "%20s seconds to import %s rows\n" `(time -p mysql $connection_string -e "load data local infile \"$results_dir/run_times.txt\" REPLACE into table run_times ignore 1 lines (scenario_id, carbon_cost, process_type, time_seconds);") 2>&1 | grep -e '^real' | sed -e 's/real //'` `wc -l "$results_dir/run_times.txt" | sed -e 's/^[^0-9]*\([0-9]*\) .*$/\1/g'`

  # Get the present year from an input file
  present_year=$(grep 'param present_year' inputs/misc_params.dat | sed -e 's/[^0-9]//g')
  
  # now import all of the non-runtime results
  for file_base_name in gen_cap trans_cap local_td_cap transmission_dispatch transmission_dispatch_optimized system_load existing_trans_cost rps_reduced_cost generator_and_storage_dispatch load_wind_solar_operating_reserve_levels consume_variables; do
    for file_name in $(ls $results_dir/*${file_base_name}_*txt | grep "[[:digit:]]"); do
      file_path="$(pwd)/$file_name"
      echo "    ${file_name}  ->  ${DB_name}._${file_base_name}"
      start_time=$(date +%s)
      file_row_count=$(wc -l "$file_path" | awk '{print ($1-1)}')
      # Customize the row count where clause to distinguish between present day results and normal results
      if [ -n "$(echo "$file_name" | grep ${results_dir}/present)" ]; then
        row_count_clause="period = $present_year"
      else
        row_count_clause="period != $present_year"
      fi
      # Import the file in question into the DB
      case $file_base_name in
        gen_cap) 
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _gen_cap ignore 1 lines \
              (scenario_id, carbon_cost, period, project_id, area_id, @junk, technology_id, @junk, @junk, new, baseload, cogen, fuel, capacity, storage_energy_capacity, capital_cost, fixed_o_m_cost);\
              select count(*) from _gen_cap where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        trans_cap)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _trans_cap ignore 1 lines \
              (scenario_id,carbon_cost,period,transmission_line_id, start_id,end_id,@junk,@junk,new,trans_mw,fixed_cost);\
              select count(*) from _trans_cap where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        local_td_cap)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _local_td_cap ignore 1 lines \
              (scenario_id, carbon_cost, period, area_id, @junk, new, local_td_mw, fixed_cost);\
              select count(*) from _local_td_cap where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        transmission_dispatch | transmission_dispatch_optimized)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _transmission_dispatch ignore 1 lines \
              (scenario_id, carbon_cost, period, transmission_line_id, receive_id, send_id, @junk, @junk, study_date, study_hour, rps_fuel_category, power_sent, power_received, hours_in_sample);\
              select count(*) from _transmission_dispatch where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        system_load)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "LOAD DATA LOCAL INFILE \"$file_path\" INTO TABLE _system_load FIELDS TERMINATED BY '\t' LINES TERMINATED BY '\n' IGNORE 1 LINES (scenario_id, carbon_cost, period, area_id, @junk, study_date, study_hour, hours_in_sample, power, satisfy_load_reduced_cost, satisfy_load_reserve_reduced_cost, res_comm_dr, ev_dr);\
              SELECT count(*) FROM _system_load WHERE scenario_id=$SCENARIO_ID AND $row_count_clause;"
          ) ;;
        existing_trans_cost)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _existing_trans_cost ignore 1 lines \
              (scenario_id, carbon_cost, period, area_id, @junk, existing_trans_cost);\
              select count(*) from _existing_trans_cost where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        rps_reduced_cost)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _rps_reduced_cost ignore 1 lines \
              (scenario_id, carbon_cost, period, rps_compliance_entity, rps_compliance_type, rps_reduced_cost);\
              select count(*) from _rps_reduced_cost where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        generator_and_storage_dispatch)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _generator_and_storage_dispatch ignore 1 lines \
              (scenario_id, carbon_cost, period, project_id, area_id, @junk, @junk, study_date, \
               study_hour, technology_id, @junk, new, baseload, cogen, storage, fuel, \
               fuel_category, hours_in_sample, power, co2_tons, heat_rate, fuel_cost, \
               carbon_cost_incurred, variable_o_m_cost, spinning_reserve, quickstart_capacity, \
               total_operating_reserve, spinning_co2_tons, spinning_fuel_cost, \
               spinning_carbon_cost_incurred, deep_cycling_amount, deep_cycling_fuel_cost, \
               deep_cycling_carbon_cost, deep_cycling_co2_tons, mw_started_up, startup_fuel_cost, \
               startup_nonfuel_cost, startup_carbon_cost, startup_co2_tons); \
              select count(*) from _generator_and_storage_dispatch where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        load_wind_solar_operating_reserve_levels)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _load_wind_solar_operating_reserve_levels ignore 1 lines \
              (scenario_id, carbon_cost, period, balancing_area, study_date, study_hour, \
               hours_in_sample, load_level, wind_generation, noncsp_solar_generation, \
               csp_generation, spinning_reserve_requirement, quickstart_capacity_requirement, \
               total_spinning_reserve_provided, total_quickstart_capacity_provided, \
               spinning_thermal_reserve_provided, spinning_nonthermal_reserve_provided, \
               quickstart_thermal_capacity_provided, quickstart_nonthermal_capacity_provided); \
              select count(*) from _load_wind_solar_operating_reserve_levels where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
        energy_consumed_and_spilled)
          db_row_count=$(
            mysql $connection_string --column-names=false -e "load data local infile \"$file_path\" \
              into table _energy_consumed_and_spilled ignore 1 lines \
              (scenario_id, carbon_cost, period, area_id, @junk, study_date, study_hour, hours_in_sample, \
              nondistributed_power_consumed, distributed_power_consumed, \
              nondistributed_power_spilled, distributed_power_spilled); \
              select count(*) from _energy_consumed_and_spilled where scenario_id=$SCENARIO_ID and $row_count_clause;"
          ) ;;
      esac
      end_time=$(date +%s)
      if [ $db_row_count -eq $file_row_count ]; then
        printf "%20s seconds to import %s rows\n" $(($end_time - $start_time)) $file_row_count
      else
        printf " -------------\n -- ERROR! Imported %d rows, but expected %d. (%d seconds.) --\n -------------\n" $db_row_count $file_row_count $(($end_time - $start_time))
#        exit
      fi
    done
  done

####################################################
# Crunch through the data
  echo 'Crunching the data...'
  data_crunch_path=tmp_data_crunch$$.sql
  echo "set @scenario_id := ${SCENARIO_ID};" >> $data_crunch_path
  cat crunch_results.sql >> $data_crunch_path
  mysql $connection_string < $data_crunch_path
  rm $data_crunch_path
else
  echo 'Skipping data import and crunching.'
fi

###################################################
# Build pivot-table like views that are easier to read

echo 'Done crunching the data...'
echo 'Outputting Excel friendly summary files'

# Make a temporary file of investment periods
invest_periods_path=tmp_invest_periods$$.txt
mysql $connection_string --column-names=false -e "select distinct(period) from gen_summary_tech where scenario_id=$SCENARIO_ID order by period;" > $invest_periods_path



# Average Generation on a TECH basis....
# Build a long query that will make one column for each investment period
select_gen_summary="SELECT distinct g.scenario_id, technology, g.carbon_cost"
while read inv_period; do 
  select_gen_summary=$select_gen_summary", IFNULL((select round(avg_power) from $DB_name._gen_summary_tech where technology_id = g.technology_id and period = '$inv_period' and carbon_cost = g.carbon_cost and scenario_id = g.scenario_id),0) as '$inv_period'"
done < $invest_periods_path
select_gen_summary=$select_gen_summary" FROM $DB_name._gen_summary_tech g join $DB_name.technologies using(technology_id);"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_summary_tech_by_period AS $select_gen_summary"

# Average Generation on a FUEL basis....
# Build a long query that will make one column for each investment period
select_gen_summary="SELECT distinct g.scenario_id, g.fuel, g.carbon_cost"
while read inv_period; do 
  select_gen_summary=$select_gen_summary", IFNULL((select round(avg_power) from $DB_name.gen_summary_fuel where fuel = g.fuel and period = '$inv_period' and carbon_cost = g.carbon_cost and scenario_id = g.scenario_id),0) as '$inv_period'"
done < $invest_periods_path
select_gen_summary=$select_gen_summary" FROM $DB_name.gen_summary_fuel g;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_summary_fuel_by_period AS $select_gen_summary"


# Generation capacity on a TECH basis..
# Build a long query that will make one column for each investment period
select_gen_cap_summary="SELECT distinct g.scenario_id, technology, g.carbon_cost"
while read inv_period; do 
  select_gen_cap_summary=$select_gen_cap_summary", IFNULL((select round(capacity) from $DB_name._gen_cap_summary_tech where technology_id = g.technology_id and period = '$inv_period' and carbon_cost = g.carbon_cost and scenario_id = g.scenario_id),0) as '$inv_period'"
done < $invest_periods_path
select_gen_cap_summary=$select_gen_cap_summary" FROM $DB_name._gen_cap_summary_tech g join $DB_name.technologies using(technology_id);"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_cap_summary_tech_by_period AS $select_gen_cap_summary"

# Generation capacity on a FUEL basis..
# Build a long query that will make one column for each investment period
select_gen_cap_summary="SELECT distinct g.scenario_id, g.fuel, g.carbon_cost"
while read inv_period; do 
  select_gen_cap_summary=$select_gen_cap_summary", IFNULL((select round(capacity) from $DB_name.gen_cap_summary_fuel where fuel = g.fuel and period = '$inv_period' and carbon_cost = g.carbon_cost and scenario_id = g.scenario_id),0) as '$inv_period'"
done < $invest_periods_path
select_gen_cap_summary=$select_gen_cap_summary" FROM $DB_name.gen_cap_summary_fuel g;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_cap_summary_fuel_by_period AS $select_gen_cap_summary"


# TECHNOLOGIES --------

# Make a temporary file of generation technologies
echo 'Getting a list of generation technologies and making technology-specific pivot tables...'
tech_path=tmp_tech$$.txt
mysql $connection_string --column-names=false -e "select technology_id, technology from technologies where technology_id in (select distinct technology_id from _gen_summary_tech WHERE scenario_id = $SCENARIO_ID) order by fuel;" > $tech_path

# The code below builds long queries that will make one column for each generation technology

# gen_cap_summary_by_tech
select_gen_cap_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period"
while read technology_id technology; do 
  select_gen_cap_summary="$select_gen_cap_summary"", IFNULL((select round(capacity) FROM $DB_name._gen_cap_summary_tech where technology_id='$technology_id' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period),0) as '$technology'"
done < $tech_path
select_gen_cap_summary="$select_gen_cap_summary"" FROM $DB_name._gen_cap_summary_tech g order by scenario_id, carbon_cost, period;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_cap_summary_by_tech AS $select_gen_cap_summary"

# gen_cap_summary_by_tech_la
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period, load_area"
while read technology_id technology; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(capacity) FROM $DB_name._gen_cap_summary_tech_la where technology_id='$technology_id' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period and area_id = g.area_id),0) as '$technology'"
done < $tech_path
select_dispatch_summary="$select_dispatch_summary"" FROM $DB_name._gen_cap_summary_tech_la g join load_areas using (area_id) order by scenario_id, carbon_cost, period, load_area;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_cap_summary_by_tech_la AS $select_dispatch_summary"



# gen_summary_by_tech
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period"
while read technology_id technology; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(avg_power) FROM $DB_name._gen_summary_tech where technology_id='$technology_id' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period),0) as '$technology'"
done < $tech_path
select_dispatch_summary="$select_dispatch_summary"" FROM $DB_name._gen_summary_tech g order by scenario_id, carbon_cost, period;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_summary_by_tech AS $select_dispatch_summary"

# gen_summary_by_tech_la
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period, load_area"
while read technology_id technology; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(avg_power) FROM $DB_name._gen_summary_tech_la where technology_id='$technology_id' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period and area_id = g.area_id),0) as '$technology'"
done < $tech_path
select_dispatch_summary="$select_dispatch_summary"" FROM $DB_name._gen_summary_tech_la g join load_areas using (area_id) order by scenario_id, carbon_cost, period, load_area;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_summary_by_tech_la AS $select_dispatch_summary"

# gen_hourly_summary_by_tech
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.study_hour, (select period FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'period', (select study_date FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'study_date', (select hours_in_sample FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'hours_in_sample', (select month FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'month', (select hour_of_day_UTC FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'hour_of_day_UTC', (select mod(hour_of_day_UTC+16,24) FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'hour_of_day_PST'"
while read technology_id technology; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(power) FROM $DB_name._gen_hourly_summary_tech where technology_id='$technology_id' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour ),0) as '$technology'"
done < $tech_path
select_dispatch_summary="$select_dispatch_summary"", system_load FROM $DB_name._gen_hourly_summary_tech g join system_load_summary_hourly using (scenario_id, carbon_cost, study_hour) order by scenario_id, carbon_cost, period, month, study_date, hour_of_day_UTC;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_hourly_summary_by_tech AS $select_dispatch_summary"

# gen_hourly_summary_la_by_tech
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.study_hour, g.area_id, load_area, (select period FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'period', (select study_date FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'study_date', (select hours_in_sample FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'hours_in_sample', (select month FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'month', (select hour_of_day_UTC FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'hour_of_day_UTC', (select mod(hour_of_day_UTC+16,24) FROM $DB_name._gen_hourly_summary_tech where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'hour_of_day_PST'"
while read technology_id technology; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(power) FROM $DB_name._gen_hourly_summary_tech_la where technology_id='$technology_id' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id),0) as '$technology'"
done < $tech_path
select_dispatch_summary="$select_dispatch_summary"", _system_load.power FROM $DB_name._gen_hourly_summary_tech_la g join $DB_name.load_areas using(area_id) join _system_load using (scenario_id, carbon_cost, study_hour, area_id) order by scenario_id, carbon_cost, period, month, study_date, hour_of_day_UTC;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_hourly_summary_la_by_tech AS $select_dispatch_summary"




# FUELS - do the same as above but on a fuel basis
# Make a temporary file of fuels
echo 'Getting a list of fuels and making fuel-specific pivot tables...'
fuel_path=tmp_fuel$$.txt
mysql $connection_string --column-names=false -e "select distinct(fuel) from $DB_name.gen_summary_fuel WHERE scenario_id=$SCENARIO_ID order by fuel;" > $fuel_path

# The code below builds long queries that will make one column for each fuel

# gen_cap_summary_by_fuel
select_gen_cap_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period"
while read fuel; do 
  select_gen_cap_summary="$select_gen_cap_summary"", IFNULL((select round(capacity) FROM $DB_name.gen_cap_summary_fuel where fuel='$fuel' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period),0) as '$fuel'"
done < $fuel_path
select_gen_cap_summary="$select_gen_cap_summary"" FROM $DB_name.gen_cap_summary_fuel g order by scenario_id, carbon_cost, period;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_cap_summary_by_fuel AS $select_gen_cap_summary"

# gen_cap_summary_by_fuel_la
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period, g.load_area"
while read fuel; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(capacity) FROM $DB_name.gen_cap_summary_fuel_la where fuel='$fuel' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period and load_area = g.load_area),0) as '$fuel'"
done < $fuel_path
select_dispatch_summary="$select_dispatch_summary"" FROM $DB_name.gen_cap_summary_fuel_la g order by scenario_id, carbon_cost, period, load_area;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_cap_summary_by_fuel_la AS $select_dispatch_summary"


# gen_summary_by_fuel 
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period"
while read fuel; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(avg_power) FROM $DB_name.gen_summary_fuel where fuel='$fuel' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period),0) as '$fuel'"
done < $fuel_path
select_dispatch_summary="$select_dispatch_summary"" FROM $DB_name.gen_summary_fuel g order by scenario_id, carbon_cost, period;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_summary_by_fuel AS $select_dispatch_summary"


# gen_summary_by_fuel_la
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.period, g.load_area"
while read fuel; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(avg_power) FROM $DB_name.gen_summary_fuel_la where fuel='$fuel' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and period = g.period and load_area = g.load_area),0) as '$fuel'"
done < $fuel_path
select_dispatch_summary="$select_dispatch_summary"" FROM $DB_name.gen_summary_fuel_la g order by scenario_id, carbon_cost, period, load_area;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_summary_by_fuel_la AS $select_dispatch_summary"


# gen_hourly_summary_by_fuel, 
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.study_hour, (select period FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'period', (select study_date FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'study_date', (select hours_in_sample FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'hours_in_sample', (select month FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'month', (select hour_of_day_UTC FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'hour_of_day_UTC', (select mod(hour_of_day_UTC+16,24) FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour limit 1) as 'hour_of_day_PST'"
while read fuel; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(power) FROM $DB_name._gen_hourly_summary_fuel where fuel='$fuel' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour ),0) as '$fuel'"
done < $fuel_path
select_dispatch_summary="$select_dispatch_summary"", system_load FROM $DB_name._gen_hourly_summary_fuel g join system_load_summary_hourly using (scenario_id, carbon_cost, study_hour) order by scenario_id, carbon_cost, period, month, study_date, hour_of_day_UTC;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_hourly_summary_by_fuel AS $select_dispatch_summary"

# gen_hourly_summary_la_by_fuel
select_dispatch_summary="SELECT distinct g.scenario_id, g.carbon_cost, g.study_hour, g.area_id, load_area, (select period FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'period', (select study_date FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'study_date', (select hours_in_sample FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'hours_in_sample', (select month FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'month', (select hour_of_day_UTC FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'hour_of_day_UTC', (select mod(hour_of_day_UTC+16,24) FROM $DB_name._gen_hourly_summary_fuel where scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id limit 1) as 'hour_of_day_PST'"
while read fuel; do 
  select_dispatch_summary="$select_dispatch_summary"", IFNULL((select round(power) FROM $DB_name._gen_hourly_summary_fuel_la where fuel='$fuel' and scenario_id = g.scenario_id and carbon_cost = g.carbon_cost and study_hour = g.study_hour and area_id = g.area_id),0) as '$fuel'"
done < $fuel_path
select_dispatch_summary="$select_dispatch_summary"", _system_load.power FROM $DB_name._gen_hourly_summary_fuel_la g join $DB_name.load_areas using(area_id) join _system_load using (scenario_id, carbon_cost, study_hour, area_id) order by scenario_id, carbon_cost, period, month, study_date, hour_of_day_UTC;"
mysql $connection_string -e "CREATE OR REPLACE VIEW gen_hourly_summary_la_by_fuel AS $select_dispatch_summary"


# delete the temporary files
rm $invest_periods_path
rm $tech_path
rm $fuel_path


###################################################
# Export summaries of the results
# Make output directories if needed
mkdir -p $results_graphing_dir

echo 'Exporting gen_summary_by_tech.txt...'
mysql $connection_string -e "select * from gen_summary_by_tech WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_summary_by_tech.txt

echo 'Exporting gen_summary_by_tech_la.txt...'
mysql $connection_string -e "select * from gen_summary_by_tech_la WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_summary_by_tech_la.txt

echo 'Exporting gen_summary_by_fuel.txt...'
mysql $connection_string -e "select * from gen_summary_by_fuel WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_summary_by_fuel.txt

echo 'Exporting gen_summary_by_fuel_la.txt...'
mysql $connection_string -e "select * from gen_summary_by_fuel_la WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_summary_by_fuel_la.txt

echo 'Exporting gen_summary_tech_by_period.txt...'
mysql $connection_string -e "select * from gen_summary_tech_by_period WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_summary_tech_by_period.txt

echo 'Exporting gen_summary_fuel_by_period.txt...'
mysql $connection_string -e "select * from gen_summary_fuel_by_period WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_summary_fuel_by_period.txt

echo 'Exporting gen_cap_summary_by_tech.txt...'
mysql $connection_string -e "select * from gen_cap_summary_by_tech WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_cap_summary_by_tech.txt

echo 'Exporting gen_cap_summary_by_fuel.txt...'
mysql $connection_string -e "select * from gen_cap_summary_by_fuel WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_cap_summary_by_fuel.txt

echo 'Exporting gen_cap_summary_by_fuel_la.txt...'
mysql $connection_string -e "select * from gen_cap_summary_by_fuel_la WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_cap_summary_by_fuel_la.txt

echo 'Exporting gen_cap_summary_by_tech_la.txt...'
mysql $connection_string -e "select * from gen_cap_summary_by_tech_la WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_cap_summary_by_tech_la.txt

echo 'Exporting gen_cap_summary_tech_by_period.txt...'
mysql $connection_string -e "select * from gen_cap_summary_tech_by_period WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_cap_summary_tech_by_period.txt

echo 'Exporting gen_cap_summary_fuel_by_period.txt...'
mysql $connection_string -e "select * from gen_cap_summary_fuel_by_period WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/gen_cap_summary_fuel_by_period.txt

echo 'Exporting co2_cc.txt...'
mysql $connection_string -e "select * from co2_cc WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/co2_cc.txt

echo 'Exporting power_cost_cc.txt...'
mysql $connection_string -e "select * from power_cost where scenario_id = $SCENARIO_ID;" > $results_graphing_dir/power_cost_cc.txt

echo 'Exporting system_load_summary.txt...'
mysql $connection_string -e "select * from system_load_summary where scenario_id = $SCENARIO_ID;" > $results_graphing_dir/system_load_summary.txt

echo 'Exporting system_load_summary_hourly.txt...'
mysql $connection_string -e "select * from system_load_summary_hourly where scenario_id = $SCENARIO_ID;" > $results_graphing_dir/system_load_summary_hourly.txt

echo 'Exporting trans_cap_summary.txt...'
mysql $connection_string -e "select * from trans_cap_summary where scenario_id = $SCENARIO_ID;" > $results_graphing_dir/trans_cap_summary.txt

echo 'Exporting transmission_avg_directed.txt...'
mysql $connection_string -e "select * from transmission_avg_directed where scenario_id = $SCENARIO_ID;" > $results_graphing_dir/transmission_avg_directed.txt

echo 'Exporting dispatch_summary_hourly_fuel.txt...'
mysql $connection_string -e "select * from gen_hourly_summary_by_fuel WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/dispatch_summary_hourly_fuel.txt

echo 'Exporting dispatch_summary_hourly_tech.txt...'
mysql $connection_string -e "select * from gen_hourly_summary_by_tech WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/dispatch_summary_hourly_tech.txt

#these take too long at the moment
# echo 'Exporting dispatch_hourly_summary_la_by_tech.txt...'
#mysql $connection_string -e "select * from gen_hourly_summary_la_by_tech WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/dispatch_hourly_summary_la_by_tech.txt

# echo 'Exporting dispatch_hourly_summary_la_by_fuel.txt...'
#mysql $connection_string -e "select * from gen_hourly_summary_la_by_fuel WHERE scenario_id = $SCENARIO_ID;" > $results_graphing_dir/dispatch_hourly_summary_la_by_fuel.txt

