#pragma once
#include <stdint.h>

struct emmc_report {
	uint32_t last_int, adma_err, ocr, pres;
};
extern struct emmc_report e_rep;

void test_emmc(void);
