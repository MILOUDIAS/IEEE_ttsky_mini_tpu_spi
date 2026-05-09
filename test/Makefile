# Makefile
 # See https://docs.cocotb.org/en/stable/quickstart.html for more info
 
 # defaults
 SIM ?= icarus
 TOPLEVEL_LANG ?= verilog
 SRC_DIR = $(PWD)/../src
 PROJECT_SOURCES = tpu_interface.v spi.v tpu.v control.v memory.v array.v pe.v tt_um_tpu.v
 
 ifneq ($(GATES),yes)
 
 # RTL simulation:
 SIM_BUILD				= sim_build/rtl
 VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
 
 else
 
 # Gate level simulation:
 SIM_BUILD				= sim_build/gl
 COMPILE_ARGS    += -DGL_TEST
 COMPILE_ARGS    += -DFUNCTIONAL
 # USE_POWER_PINS must be defined for GL: the netlist (from either
 # local librelane with VERILOG_DEFINES=USE_POWER_PINS, or TT's
 # tt-gds-action) instantiates FILLER/decap cells that connect VPWR/
 # VGND/VNB/VPB. Without -DUSE_POWER_PINS the loaded sky130 cell
 # models don't declare those ports and iverilog elaboration fails
 # with thousands of "port VPWR is not a port of FILLER_*" errors.
 COMPILE_ARGS    += -DUSE_POWER_PINS
 COMPILE_ARGS    += -DSIM
 COMPILE_ARGS    += -DUNIT_DELAY=\#1
 VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
 VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v
 
 # this gets copied in by the GDS action workflow
 VERILOG_SOURCES += $(PWD)/gate_level_netlist.v
 
 endif
 
 # Allow sharing configuration between design and testbench via `include`:
 COMPILE_ARGS 		+= -I$(SRC_DIR)
 
 # Include the testbench sources:
 VERILOG_SOURCES += $(PWD)/tb.v
 TOPLEVEL = tb
 
 # MODULE is the basename of the Python test file
 MODULE = test

 
 # include cocotb's make rules to take care of the simulator setup
 include $(shell cocotb-config --makefiles)/Makefile.sim
