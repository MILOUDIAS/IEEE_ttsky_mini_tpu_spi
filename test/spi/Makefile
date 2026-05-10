SIM ?= icarus
TOPLEVEL_LANG ?= verilog

SRC_DIR = $(PWD)/../../src

VERILOG_SOURCES += $(SRC_DIR)/spi.v
TOPLEVEL = spi
MODULE = test_spi

include $(shell cocotb-config --makefiles)/Makefile.sim
