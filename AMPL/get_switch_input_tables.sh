#!/bin/bash
# get_switch_input_tables.sh
# SYNOPSIS
#		./get_switch_input_tables.sh 
# DESCRIPTION
# 	Pull input data for Switch from databases and other sources, formatting it for AMPL
# This script assumes that the input database has already been built by the script 'Build WECC Cap Factors.sql'
# 
# INPUTS
#  --help                   Print this message
#  -u [DB Username]
#  -p [DB Password]
#  -D [DB name]
#  -P/--port [port number]
#  -h [DB server]
# All arguments are optional.

# This function assumes that the lines at the top of the file that start with a # and a space or tab 
# comprise the help message. It prints the matching lines with the prefix removed and stops at the first blank line.
# Consequently, there needs to be a blank line separating the documentation of this program from this "help" function
function print_help {
	last_line=$(( $(egrep '^[ \t]*$' -n -m 1 $0 | sed 's/:.*//') - 1 ))
	head -n $last_line $0 | sed -e '/^#[ 	]/ !d' -e 's/^#[ 	]//'
}


# Export SWITCH input data from the Switch inputs database into text files that will be read in by AMPL
# This script assumes that the input database has already been built by the script 'Build WECC Cap Factors.sql'

write_to_path='inputs'

db_server="switch-db1.erg.berkeley.edu"
DB_name="switch_inputs_wecc_v2_2"
port=3306

###################################################
# Detect optional command-line arguments
help=0
while [ -n "$1" ]; do
case $1 in
  -u)
    user=$2; shift 2 ;;
  -p)
    password=$2; shift 2 ;;
  -P)
    port=$2; shift 2 ;;
  --port)
    port=$2; shift 2 ;;
  -D)
    DB_name=$2; shift 2 ;;
  -h)
    db_server=$2; shift 2 ;;
  --help)
		print_help; exit ;;
  *)
    echo "Unknown option $1"
		print_help; exit ;;
esac
done

##########################
# Get the user name and password 
# Note that passing the password to mysql via a command line parameter is considered insecure
#	http://dev.mysql.com/doc/refman/5.0/en/password-security.html
if [ ! -n "$user" ]
then 
	echo "User name for MySQL $DB_name on $db_server? "
	read user
fi
if [ ! -n "$password" ]
then 
	echo "Password for MySQL $DB_name on $db_server? "
	stty_orig=`stty -g`   # Save screen settings
	stty -echo            # To keep the password vaguely secure, don't let it show to the screen
	read password
	stty $stty_orig       # Restore screen settings
fi

connection_string="-h $db_server --port $port -u $user -p$password $DB_name"
test_connection=`mysql $connection_string --column-names=false -e "select count(*) from existing_plants;"`
if [ ! -n "$test_connection" ]
then
	connection_string=`echo "$connection_string" | sed -e "s/ -p[^ ]* / -pXXX /"`
	echo "Could not connect to database with settings: $connection_string"
	exit 0
fi


###########################
# These next variables determine which input data is used

# get the present year that will make present day cost optimization possible
present_year=`date "+%Y"`

INTERMITTENT_PROJECTS_SELECTION="(( avg_cap_factor_percentile_by_intermittent_tech >= 0.75 or cumulative_avg_MW_tech_load_area <= 3 * total_yearly_load_mwh / 8766 or rank_by_tech_in_load_area <= 5 or avg_cap_factor_percentile_by_intermittent_tech is null) and technology <> 'Concentrating_PV')"

read SCENARIO_ID < scenario_id.txt

export REGIONAL_MULTIPLIER_SCENARIO_ID=$(mysql $connection_string --column-names=false -e "select regional_cost_multiplier_scenario_id from scenarios_v2 where scenario_id=$SCENARIO_ID;")
export REGIONAL_FUEL_COST_SCENARIO_ID=$(mysql $connection_string --column-names=false -e "select regional_fuel_cost_scenario_id from scenarios_v2 where scenario_id=$SCENARIO_ID;")
export GEN_PRICE_SCENARIO_ID=$(mysql $connection_string --column-names=false -e "select gen_price_scenario_id from scenarios_v2 where scenario_id=$SCENARIO_ID;")
export SCENARIO_NAME=$(mysql $connection_string --column-names=false -e "select scenario_name from scenarios_v2 where scenario_id=$SCENARIO_ID;")
export TRAINING_SET_ID=$(mysql $connection_string --column-names=false -e "select training_set_id from scenarios_v2 where scenario_id = $SCENARIO_ID;")
export LOAD_SCENARIO_ID=$(mysql $connection_string --column-names=false -e "select load_scenario_id from training_sets where training_set_id = $TRAINING_SET_ID;")
export ENABLE_RPS=$(mysql $connection_string --column-names=false -e "select enable_rps from scenarios_v2 where scenario_id=$SCENARIO_ID;")
export ENABLE_CARBON_CAP=$(mysql $connection_string --column-names=false -e "select enable_carbon_cap from scenarios_v2 where scenario_id=$SCENARIO_ID;")
export STUDY_START_YEAR=$(mysql $connection_string --column-names=false -e "select study_start_year from training_sets where training_set_id=$TRAINING_SET_ID;")
export STUDY_END_YEAR=$(mysql $connection_string --column-names=false -e "select study_start_year + years_per_period*number_of_periods from training_sets where training_set_id=$TRAINING_SET_ID;")
number_of_years_per_period=$(mysql $connection_string --column-names=false -e "select years_per_period from training_sets where training_set_id=$TRAINING_SET_ID;")
###########################
# Export data to be read into ampl.

cd  $write_to_path

echo 'Exporting Scenario Information'
echo 'Scenario Information' > scenario_information.txt
mysql $connection_string -e "select * from scenarios_v2 where scenario_id = $SCENARIO_ID;" >> scenario_information.txt
echo 'Training Set Information' >> scenario_information.txt
mysql $connection_string -e "select * from training_sets where training_set_id=$TRAINING_SET_ID;" >> scenario_information.txt

# The general format for the following files is for the first line to be:
#	ampl.tab [number of key columns] [number of non-key columns]
# col1_name col2_name ...
# [rows of data]

echo 'Copying data from the database to input files...'

echo '	study_hours.tab...'
echo ampl.tab 1 5 > study_hours.tab
mysql $connection_string -e "\
SELECT \
  DATE_FORMAT(datetime_utc,'%Y%m%d%H') AS hour, period, \
  DATE_FORMAT(datetime_utc,'%Y%m%d') AS date, hours_in_sample, \
  MONTH(datetime_utc) AS month_of_year, HOUR(datetime_utc) as hour_of_day \
FROM _training_set_timepoints JOIN study_timepoints  USING (timepoint_id) \
WHERE training_set_id=$TRAINING_SET_ID order by 1;" >> study_hours.tab

echo '	load_areas.tab...'
echo ampl.tab 1 10 > load_areas.tab
mysql $connection_string -e "select load_area, area_id as load_area_id, primary_nerc_subregion as balancing_area, rps_compliance_entity, economic_multiplier, max_coincident_load_for_local_td, local_td_new_annual_payment_per_mw, local_td_sunk_annual_payment, transmission_sunk_annual_payment, ccs_distance_km, bio_gas_capacity_limit_mmbtu_per_hour from load_area_info;" >> load_areas.tab

echo '	balancing_areas.tab...'
echo ampl.tab 1 4 > balancing_areas.tab
mysql $connection_string -e "select balancing_area, load_only_spinning_reserve_requirement, wind_spinning_reserve_requirement, solar_spinning_reserve_requirement, quickstart_requirement_relative_to_spinning_reserve_requirement from balancing_areas;" >> balancing_areas.tab

echo '	rps_compliance_entity_targets.tab...'
echo ampl.tab 2 1 > rps_compliance_entity_targets.tab
mysql $connection_string -e "select rps_compliance_entity, compliance_year as rps_compliance_year, compliance_fraction as rps_compliance_fraction from rps_compliance_entity_targets where compliance_year >= $STUDY_START_YEAR and compliance_year <= $STUDY_END_YEAR;" >> rps_compliance_entity_targets.tab

echo '	carbon_cap_targets.tab...'
echo ampl.tab 1 1 > carbon_cap_targets.tab
mysql $connection_string -e "select year, carbon_emissions_relative_to_base from carbon_cap_targets where year >= $STUDY_START_YEAR and year <= $STUDY_END_YEAR;" >> carbon_cap_targets.tab

echo '	transmission_lines.tab...'
echo ampl.tab 2 5 > transmission_lines.tab
mysql $connection_string -e "select load_area_start, load_area_end, existing_transfer_capacity_mw, transmission_line_id, transmission_length_km, transmission_efficiency, new_transmission_builds_allowed from transmission_lines order by 1,2;" >> transmission_lines.tab

echo '	system_load.tab...'
echo ampl.tab 2 2 > system_load.tab
mysql $connection_string -e "call prepare_load_exports($TRAINING_SET_ID); select load_area, DATE_FORMAT(datetime_utc,'%Y%m%d%H') as hour, system_load, present_day_system_load from scenario_loads_export WHERE training_set_id=$TRAINING_SET_ID; call clean_load_exports($TRAINING_SET_ID); "  >> system_load.tab

echo '	max_system_loads.tab...'
echo ampl.tab 2 1 > max_system_loads.tab
mysql $connection_string -e "\
SELECT load_area, YEAR(now()) as period, max(power) as max_system_load \
  FROM _load_projections \
    JOIN training_sets USING(load_scenario_id) \
    JOIN load_area_info    USING(area_id) \
  WHERE training_set_id=$TRAINING_SET_ID AND future_year = YEAR(now())  \
  GROUP BY 1,2 \
UNION \
SELECT load_area, period_start as period, max(power) as max_system_load \
  FROM training_sets \
    JOIN _load_projections     USING(load_scenario_id)  \
    JOIN load_area_info        USING(area_id) \
    JOIN training_set_periods USING(training_set_id)  \
  WHERE training_set_id=$TRAINING_SET_ID  \
    AND future_year = FLOOR( period_start + years_per_period / 2) \
  GROUP BY 1,2; " >> max_system_loads.tab

echo '	existing_plants.tab...'
echo ampl.tab 3 11 > existing_plants.tab
mysql $connection_string -e "select project_id, load_area, technology, plant_name, eia_id, capacity_mw, heat_rate, cogen_thermal_demand_mmbtus_per_mwh, if(start_year = 0, 1900, start_year) as start_year, overnight_cost, connect_cost_per_mw, fixed_o_m, variable_o_m, ep_location_id from existing_plants order by 1, 2, 3;" >> existing_plants.tab

echo '	existing_intermittent_plant_cap_factor.tab...'
echo ampl.tab 4 1 > existing_intermittent_plant_cap_factor.tab
mysql $connection_string -e "\
SELECT project_id, load_area, technology, DATE_FORMAT(datetime_utc,'%Y%m%d%H') as hour, cap_factor \
FROM _training_set_timepoints \
  JOIN study_timepoints USING(timepoint_id)\
  JOIN load_scenario_historic_timepoints USING(timepoint_id)\
  JOIN existing_intermittent_plant_cap_factor ON(historic_hour=hour)\
WHERE training_set_id=$TRAINING_SET_ID AND load_scenario_id=$LOAD_SCENARIO_ID;\
" >> existing_intermittent_plant_cap_factor.tab

echo '	hydro_monthly_limits.tab...'
echo ampl.tab 4 1 > hydro_monthly_limits.tab
mysql $connection_string -e "\
CREATE TEMPORARY TABLE study_dates_export\
  SELECT distinct period, YEAR(hours.datetime_utc) as year, MONTH(hours.datetime_utc) AS month, DATE_FORMAT(study_timepoints.datetime_utc,'%Y%m%d') AS study_date\
  FROM _training_set_timepoints \
    JOIN _load_projections USING (timepoint_id)\
    JOIN study_timepoints  USING (timepoint_id)\
    JOIN hours ON(historic_hour=hournum)\
  WHERE training_set_id=$TRAINING_SET_ID \
    AND load_scenario_id = $LOAD_SCENARIO_ID\
  ORDER BY 1,2;\
SELECT project_id, load_area, technology, study_date as date, ROUND(avg_output,1) AS avg_output\
  FROM hydro_monthly_limits \
    JOIN study_dates_export USING(year, month);" >> hydro_monthly_limits.tab

echo '	proposed_projects.tab...'
echo ampl.tab 3 11 > proposed_projects.tab
mysql $connection_string -e "select project_id, proposed_projects.load_area, technology, if(location_id is NULL, 0, location_id) as location_id, if(ep_project_replacement_id is NULL, 0, ep_project_replacement_id) as ep_project_replacement_id, if(capacity_limit is NULL, 0, capacity_limit) as capacity_limit, if(capacity_limit_conversion is NULL, 0, capacity_limit_conversion) as capacity_limit_conversion, heat_rate, cogen_thermal_demand, connect_cost_per_mw, round(overnight_cost*overnight_adjuster) as overnight_cost, fixed_o_m, variable_o_m, overnight_cost_change from proposed_projects join load_area_info using (area_id) join generator_price_adjuster using (technology_id) where generator_price_adjuster.gen_price_scenario_id=$GEN_PRICE_SCENARIO_ID and $INTERMITTENT_PROJECTS_SELECTION;" >> proposed_projects.tab

echo '	generator_info.tab...'
echo ampl.tab 1 27 > generator_info.tab
mysql $connection_string -e "select technology, technology_id, min_build_year, fuel,  construction_time_years, year_1_cost_fraction, year_2_cost_fraction, year_3_cost_fraction, year_4_cost_fraction, year_5_cost_fraction, year_6_cost_fraction, max_age_years, forced_outage_rate, scheduled_outage_rate, can_build_new, ccs, intermittent, resource_limited, baseload, dispatchable, cogen, min_build_capacity, competes_for_space, storage, storage_efficiency, max_store_rate, max_spinning_reserve_fraction_of_capacity, heat_rate_penalty_spinning_reserve from generator_info;" >> generator_info.tab

echo '	fuel_costs.tab...'
echo ampl.tab 3 1 > fuel_costs.tab
mysql $connection_string -e "select load_area, fuel, year, fuel_price from fuel_prices_regional where scenario_id = $REGIONAL_FUEL_COST_SCENARIO_ID and year <= $STUDY_END_YEAR order by load_area, fuel, year" >> fuel_costs.tab

echo '	biomass_supply_curve_slope.tab...'
echo ampl.tab 3 1 > biomass_supply_curve_slope.tab
mysql $connection_string -e "\
SELECT load_area, period_start as period, breakpoint_id, price_dollars_per_mmbtu_surplus_adjusted \
FROM biomass_solid_supply_curve, training_set_periods \
WHERE year=period_start+(period_end-period_start+1)/2 \
  AND training_set_id=$TRAINING_SET_ID \
UNION \
SELECT load_area, $present_year, breakpoint_id, price_dollars_per_mmbtu_surplus_adjusted \
FROM biomass_solid_supply_curve, training_set_periods \
WHERE year=$present_year AND training_set_id=$TRAINING_SET_ID \
order by load_area, period, breakpoint_id ;" >> biomass_supply_curve_slope.tab

echo '	biomass_supply_curve_breakpoint.tab...'
echo ampl.tab 3 1 > biomass_supply_curve_breakpoint.tab
mysql $connection_string -e "\
SELECT load_area, period_start as period, breakpoint_id, breakpoint_mmbtu_per_year \
FROM biomass_solid_supply_curve, training_set_periods \
WHERE year=period_start+(period_end-period_start+1)/2 \
  AND breakpoint_mmbtu_per_year is not null \
  AND training_set_id=$TRAINING_SET_ID \
UNION \
SELECT load_area, $present_year, breakpoint_id, breakpoint_mmbtu_per_year \
FROM biomass_solid_supply_curve, training_set_periods \
WHERE year=$present_year AND training_set_id=$TRAINING_SET_ID \
  AND breakpoint_mmbtu_per_year is not null \
order by load_area, period, breakpoint_id ;"  >> biomass_supply_curve_breakpoint.tab

echo '	fuel_info.tab...'
echo ampl.tab 1 4 > fuel_info.tab
mysql $connection_string -e "select fuel, rps_fuel_category, biofuel, carbon_content, carbon_sequestered from fuel_info;" >> fuel_info.tab

echo '	fuel_qualifies_for_rps.tab...'
echo ampl.tab 2 1 > fuel_qualifies_for_rps.tab
mysql $connection_string -e "select rps_compliance_entity, rps_fuel_category, qualifies from fuel_qualifies_for_rps;" >> fuel_qualifies_for_rps.tab


echo '	misc_params.dat...'
echo "param scenario_id           := $SCENARIO_ID;" >  misc_params.dat
echo "param enable_rps            := $ENABLE_RPS;"  >> misc_params.dat
echo "param enable_carbon_cap     := $ENABLE_CARBON_CAP;"  >> misc_params.dat
echo "param num_years_per_period  := $number_of_years_per_period;"  >> misc_params.dat
echo "param present_year  := $present_year;"  >> misc_params.dat

echo '	cap_factor.tab...'
echo ampl.tab 4 1 > cap_factor.tab
mysql $connection_string -e "\
select project_id, load_area, technology, DATE_FORMAT(datetime_utc,'%Y%m%d%H') as hour, cap_factor  \
  FROM _training_set_timepoints \
    JOIN study_timepoints USING(timepoint_id)\
    JOIN load_scenario_historic_timepoints USING(timepoint_id)\
    JOIN _cap_factor_intermittent_sites ON(historic_hour=hour)\
    JOIN _proposed_projects USING(project_id)\
    JOIN load_area_info USING(area_id)\
  WHERE training_set_id=$TRAINING_SET_ID \
    AND load_scenario_id=$LOAD_SCENARIO_ID \
    AND $INTERMITTENT_PROJECTS_SELECTION;" >> cap_factor.tab

cd ..
