###################################################################
# SDC File for Reconfigurable Edge AI Core
# Target: Synopsys SAED 14nm FinFET - High Performance (1.5ns)
###################################################################
set sdc_version 2.1

# -----------------------------------------------------------------
# 1. Units & Operating Conditions 
# -----------------------------------------------------------------
set_units -time ns -resistance kOhm -capacitance pF -voltage V -current uA

set_operating_conditions -analysis_type bc_wc \
    -max ss0p72v125c -max_library saed14hvt_cg_ss0p72v125c \
    -min ff0p88vm40c -min_library saed14lvt_base_ff0p88vm40c

set_wire_load_mode top
set_wire_load_model -name 16000 -library saed14rvt_base_tt0p8v25c

# -----------------------------------------------------------------
# 2. Design Rule Constraints (DRC)
# -----------------------------------------------------------------
set_max_fanout 200 [current_design]
set_max_capacitance 100 [current_design]
set_max_transition 0.3 [current_design]

# -----------------------------------------------------------------
# 3. Clock Definition (Aggressive 1.5ns / 666 MHz Target)
# -----------------------------------------------------------------
create_clock -name clk -period 1.75 -waveform {0 0.875} [get_ports clk]

set_clock_latency 0.5 [get_clocks clk]
set_clock_latency -source 0.5 [get_clocks clk]

# Reduced uncertainty to fit the tighter 1.5ns timing budget
set_clock_uncertainty 0.1 [get_clocks clk]

set_clock_transition -max -rise 0.3 [get_clocks clk]
set_clock_transition -max -fall 0.3 [get_clocks clk]
set_clock_transition -min -rise 0.3 [get_clocks clk]
set_clock_transition -min -fall 0.3 [get_clocks clk]

# -----------------------------------------------------------------
# 4. Environmental Attributes (Driving Cells & Output Loads)
# -----------------------------------------------------------------
# Apply buffer to ALL inputs (except the clock)
set inputs_excluding_clk [remove_from_collection [all_inputs] [get_ports clk]]

set_driving_cell -lib_cell SAEDRVT14_BUF_4 \
                 -library saed14rvt_base_tt0p8v25c \
                 -pin X $inputs_excluding_clk

# Apply standard pin load to ALL outputs
set_load -pin_load 0.01201 [all_outputs]

# -----------------------------------------------------------------
# 5. I/O Timing Delays (Scaled for 1.5ns Clock)
# -----------------------------------------------------------------
# Input Delays: Assume external logic consumes 0.3ns, leaving 1.2ns for internal
set_input_delay -clock clk -max 0.3 $inputs_excluding_clk
set_input_delay -clock clk -min 0.1 $inputs_excluding_clk

# Output Delays: Give external logic 0.3ns to capture, requiring our data to be ready early
set_output_delay -clock clk -max 0.3 [all_outputs]
set_output_delay -clock clk -min 0.1 [all_outputs]

# -----------------------------------------------------------------
# 6. Path Grouping (For cleaner Timing Reports)
# -----------------------------------------------------------------
group_path -name CLOCK   -to [get_clocks clk]
group_path -name INPUTS  -through $inputs_excluding_clk
group_path -name OUTPUTS -to [all_outputs]
group_path -name COMBO   -from $inputs_excluding_clk -to [all_outputs]
