
# Target: SAED 14nm FinFET 
set_host_options -max_cores 4
set DESIGN_REF_PATH "/home/synopsys/installs/LIBRARIES/SAED14_EDK"

set TARGET_LIBRARY_FILES "\
$DESIGN_REF_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/base/saed14rvt_base_tt0p8v25c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/base/saed14rvt_base_ss0p72v125c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/base/saed14rvt_base_ff0p88vm40c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_HVT/liberty/nldm/base/saed14hvt_base_tt0p8v25c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_HVT/liberty/nldm/base/saed14hvt_base_ss0p72v125c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_HVT/liberty/nldm/base/saed14hvt_base_ff0p88vm40c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_LVT/liberty/nldm/base/saed14lvt_base_tt0p8v25c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_LVT/liberty/nldm/base/saed14lvt_base_ss0p72v125c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_LVT/liberty/nldm/base/saed14lvt_base_ff0p88vm40c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_HVT/liberty/nldm/cg/saed14hvt_cg_tt0p8v25c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_HVT/liberty/nldm/cg/saed14hvt_cg_ss0p72v125c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_HVT/liberty/nldm/cg/saed14hvt_cg_ff0p88vm40c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/cg/saed14rvt_cg_tt0p8v25c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/cg/saed14rvt_cg_ss0p72v125c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_RVT/liberty/nldm/cg/saed14rvt_cg_ff0p88vm40c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_LVT/liberty/nldm/cg/saed14lvt_cg_tt0p8v25c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_LVT/liberty/nldm/cg/saed14lvt_cg_ss0p72v125c.db \
$DESIGN_REF_PATH/SAED14nm_EDK_STD_LVT/liberty/nldm/cg/saed14lvt_cg_ff0p88vm40c.db"

set LINK_LIBRARY_FILES "* $TARGET_LIBRARY_FILES"
set link_library $LINK_LIBRARY_FILES 
set target_library $TARGET_LIBRARY_FILES

set power_enable_analysis true

analyze -library WORK -format verilog {
    ./icg_cell.v
    ./csa_15bit.v
    ./dadda_mult_8x7.v
    ./bf16_approx_trunc.v
    ./add_bf16_pipelined.v
    ./co_cluster.v
    ./reconfig_conv_core.v
}
elaborate reconfig_conv_core
current_design reconfig_conv_core
set_fix_multiple_port_nets -all -buffer_constants [get_designs reconfig_conv_core]

source -echo ./con.sdc
check_design
link

set_operating_conditions -library saed14rvt_base_tt0p8v25c tt0p8v25c

# Safe Multibit Mapping (Good for Power/Area, safe for ICC2 Routing)
set compile_enable_multibit_mapping true

# Force absolute minimum area
set_max_area 0

# Relax DRVs to prevent "panic buffering"
set_max_transition 0.175 [current_design]
set_max_capacitance 0.175 [current_design]

set_app_var compile_limit_area_strategy true
uniquify

set_clock_gating_style -sequential_cell latch \
                       -positive_edge_logic {integrated} \
                       -control_point before \
                       -observation_point false

identify_clock_gating

# Ensure SAIF reads accurately to prevent default toggle inflation

read_saif -input power_144bit_folded.saif -instance tb_power_eval_144bit_folded/u_dut

compile_ultra -area_high_effort_script -gate_clock -retime
compile_ultra -incremental -area_high_effort_script

read_saif -input power_144bit_folded.saif -instance tb_power_eval_144bit_folded/u_dut

change_names -rules verilog -verbose -hier

report_area -hierarchy > area_report_with_cache_144_6.txt
report_power -hierarchy > power_report_with_cache_144_6.txt
report_timing -delay_type max > setup_timing_report_144_6.txt
report_timing -delay_type min > hold_timing_report_144_6.txt
report_clock_gating > clock_gating_report_144_6.txt
report_qor > qor_summary_144_6.txt

write -f verilog -h -out ./reconfig_conv_core_gate_level_144_6.v
write_sdc ./reconfig_conv_core_final_144_6.sdc

# Save the binary database for ICC2
write -format ddc -hierarchy -output ./reconfig_conv_core_cache_final_144_5.ddc

exit	
