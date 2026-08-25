# Focused FPGA technology mapping for the SD-loader SPI controller.

FPGA_SPI_SYNTH_DIR ?= build/fpga/xc7a100t/spi-synth
FPGA_SPI_SYNTH_JSON := $(FPGA_SPI_SYNTH_DIR)/spi.json
FPGA_SPI_SYNTH_LOG := $(FPGA_SPI_SYNTH_DIR)/yosys.log

$(FPGA_SPI_SYNTH_JSON): rtl/periph/spi/spi.v
	@mkdir -p '$(FPGA_SPI_SYNTH_DIR)'
	yosys -q -l '$(FPGA_SPI_SYNTH_LOG)' -p \
		'read_verilog -sv $<; hierarchy -check -top openrv64_spi; synth_xilinx -family xc7 -top openrv64_spi; stat; write_json $@'

.PHONY: fpga-spi-synth verify-fpga-spi-synth
fpga-spi-synth: $(FPGA_SPI_SYNTH_JSON)

verify-fpga-spi-synth: $(FPGA_SPI_SYNTH_JSON)
	@test -s '$(FPGA_SPI_SYNTH_JSON)'
	@test "$$(rg -c '\"type\": \"RAMB36E1\"' \
		'$(FPGA_SPI_SYNTH_JSON)')" -eq 2
	@printf 'OPENRV64 FPGA SPI SYNTH PASS path=%s RAMB36=%s\n' \
		'$(FPGA_SPI_SYNTH_JSON)' \
		"$$(rg -c '\"type\": \"RAMB36E1\"' \
		'$(FPGA_SPI_SYNTH_JSON)')"

.PHONY: verify-fpga-sd-boot-spi-clock-default
verify-fpga-sd-boot-spi-clock-default:
	@test "$$(FPGA_SD_BOOT_PRINT_CLOCK_CONFIG=1 \
		synth/fpga/xc7a100t/build_sd_boot_bitstream.sh)" = \
		'core_clock_hz=14000000 spi_fast_half_period_cycles=1 spi_fast_clock_hz=7000000'
	@test "$$(FPGA_SD_BOOT_PRINT_CLOCK_CONFIG=1 FPGA_CORE_CLOCK_HZ=20000000 \
		FPGA_CORE_CLOCK_MULTIPLY=10 FPGA_CORE_CLOCK_DIVIDE=50 \
		synth/fpga/xc7a100t/build_sd_boot_bitstream.sh)" = \
		'core_clock_hz=20000000 spi_fast_half_period_cycles=1 spi_fast_clock_hz=10000000'
	@test "$$(FPGA_SD_BOOT_PRINT_CLOCK_CONFIG=1 FPGA_CORE_CLOCK_HZ=30000000 \
		FPGA_CORE_CLOCK_MULTIPLY=9 FPGA_CORE_CLOCK_DIVIDE=30 \
		synth/fpga/xc7a100t/build_sd_boot_bitstream.sh)" = \
		'core_clock_hz=30000000 spi_fast_half_period_cycles=2 spi_fast_clock_hz=7500000'
	@if FPGA_SD_BOOT_PRINT_CLOCK_CONFIG=1 FPGA_CORE_CLOCK_HZ=30000000 \
		FPGA_CORE_CLOCK_MULTIPLY=9 FPGA_CORE_CLOCK_DIVIDE=30 \
		FPGA_SPI_FAST_HALF_PERIOD_CYCLES=1 \
		synth/fpga/xc7a100t/build_sd_boot_bitstream.sh \
		>/dev/null 2>&1; then exit 1; fi
	@printf 'OPENRV64 FPGA SPI CLOCK DEFAULT PASS core14=7000000 core20=10000000 core30=7500000\n'
