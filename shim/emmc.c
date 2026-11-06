/*
 * Pixel 3a (SDM670) eMMC bring-up probe: sdhci-msm-v5 at 0x7c4000, taken over
 * as the bootloader left it (clock, bus width and HS400 timing untouched; we
 * never reset the controller). Polled, MMU off, strict 32-bit register access.
 *
 * Stage 1: CMD17 through the PIO buffer port -> GPT header and entries.
 * Stage 2: the same sector through ADMA2 (32-bit descriptors) -> compare.
 * The result goes to the on-screen console; the same code is ported into the
 * xnu driver once it is proven here.
 */
#include <stdint.h>
#include "console.h"
#include "emmc.h"

#define HC		0x7c4000UL

#define R_BLK		0x04	/* [11:0] size, [31:16] count */
#define R_ARG		0x08
#define R_XFER_CMD	0x0c	/* [15:0] transfer mode, [31:16] command */
#define R_RESP0		0x10
#define R_DATA		0x20
#define R_PRESENT	0x24
#define R_HOSTCTL	0x28	/* byte0 host control, byte1 power, ... */
#define R_CLK_TOUT_RST	0x2c	/* [15:0] clock, [23:16] data timeout, [31:24] reset */
#define R_INT		0x30	/* [15:0] normal, [31:16] error */
#define R_INT_EN	0x34
#define R_CAPS		0x40
#define R_ADMA_ERR	0x54
#define R_ADMA_ADDR	0x58
#define R_VER_SLOT	0xfc	/* [31:16] host version */
#define R_INT_EN_ALL	0x34
/* sdhci-msm core registers (hc_mem; no separate mci block on v5) */
#define C_PWR_STATUS	0xdc
#define C_PWR_MASK	0xe0
#define C_PWR_CLEAR	0xe4
#define C_PWR_CTL	0xe8

#define PS_CMD_INHIBIT	(1u << 0)
#define PS_DAT_INHIBIT	(1u << 1)

#define INT_CMD_DONE	(1u << 0)
#define INT_XFER_DONE	(1u << 1)
#define INT_DMA		(1u << 3)
#define INT_BUF_RD	(1u << 5)
#define INT_ERR		(1u << 15)

#define TM_DMA		(1u << 0)
#define TM_BLKCNT	(1u << 1)
#define TM_AUTO12	(1u << 2)
#define TM_READ		(1u << 4)
#define TM_MULTI	(1u << 5)

#define CMD(i, flags)	((((uint32_t)(i) << 8) | (flags)) << 16)
#define C_R1_DATA	(0x02 | 0x08 | 0x10 | 0x20)	/* 48-bit, CRC, index check, data */
#define C_R1		(0x02 | 0x08 | 0x10)

static inline uint32_t rd(uint32_t o) { return *(volatile uint32_t *)(HC + o); }
static inline void wr(uint32_t o, uint32_t v) { *(volatile uint32_t *)(HC + o) = v; }
static inline uint64_t ticks(void)
{
	uint64_t v;
	__asm__ volatile("isb; mrs %0, cntpct_el0" : "=r"(v));
	return v;
}

/* 19.2 MHz counter */
static int wait_for(uint32_t off, uint32_t mask, uint32_t want, uint32_t ms)
{
	uint64_t end = ticks() + 19200ull * ms;
	while (ticks() < end)
		if ((rd(off) & mask) == want)
			return 0;
	return -1;
}

static void reset_lines(void)
{
	wr(R_CLK_TOUT_RST, (rd(R_CLK_TOUT_RST) & 0x00ffffff) | (6u << 24));	/* CMD + DAT line reset */
	wait_for(R_CLK_TOUT_RST, 6u << 24, 0, 100);
}

static void wr8(uint32_t o, uint8_t v)
{
	uint32_t sh = (o & 3) * 8, a = o & ~3u;
	wr(a, (rd(a) & ~(0xffu << sh)) | ((uint32_t)v << sh));
}

static void delay_us(uint32_t us)
{
	uint64_t end = ticks() + 19ull * us;
	while (ticks() < end)
		;
}

/* sdhci-msm: a bus power / IO voltage write only completes after software acks the power IRQ. */
static uint32_t pwr_handshake(void)
{
	uint32_t seen = 0;
	for (int i = 0; i < 200; i++) {
		uint32_t st = rd(C_PWR_STATUS) & 0xff;
		if (st) {
			uint32_t ack = 0;
			seen |= st;
			wr(C_PWR_CLEAR, st);
			if (st & 0x3)
				ack |= 1;	/* BUS_OFF/BUS_ON -> BUS_SUCCESS */
			if (st & 0xc)
				ack |= 4;	/* IO_LOW/IO_HIGH -> IO_SUCCESS */
			wr(C_PWR_CTL, ack);
		}
		delay_us(500);
	}
	return seen;
}

/* SD clock off, set the divided-clock divider N (SDCLK = base / 2N, N=0: base), on again. */
static int set_clock(uint32_t n)
{
	uint32_t c = rd(R_CLK_TOUT_RST) & 0xffff0000;
	wr(R_CLK_TOUT_RST, c);						/* everything off */
	uint32_t v = ((n & 0xff) << 8) | (((n >> 8) & 3) << 6) | 1;	/* + internal clock */
	wr(R_CLK_TOUT_RST, c | v);
	if (wait_for(R_CLK_TOUT_RST, 2, 2, 100))
		return -1;						/* internal clock not stable */
	wr(R_CLK_TOUT_RST, c | v | 4);					/* SD clock enable */
	delay_us(2000);
	return 0;
}

/* ADMA2 32-bit descriptor table + data buffer: both inside our image. */
static uint32_t adma_tbl[8] __attribute__((aligned(8)));
static uint8_t buf[4096] __attribute__((aligned(512)));
static uint8_t pio[512] __attribute__((aligned(8)));

struct emmc_report e_rep;

static int send(uint32_t cmd, uint32_t arg, uint32_t xfer_mode)
{
	if (wait_for(R_PRESENT, PS_CMD_INHIBIT | PS_DAT_INHIBIT, 0, 100))
		return -1;
	wr(R_INT, 0xffffffff);
	wr(R_ARG, arg);
	wr(R_XFER_CMD, cmd | xfer_mode);
	if (wait_for(R_INT, INT_CMD_DONE | INT_ERR, INT_CMD_DONE, 200)) {
		e_rep.last_int = rd(R_INT);
		reset_lines();
		return -2;
	}
	wr(R_INT, INT_CMD_DONE);
	return 0;
}

/* One 512-byte block via the PIO buffer port (CMD17, or CMD8 EXT_CSD). */
static int read_pio_cmd(uint32_t idx, uint32_t arg, uint8_t *out)
{
	wr(R_BLK, (1u << 16) | 512);
	int rc = send(CMD(idx, C_R1_DATA), arg, TM_READ);
	if (rc)
		return rc;
	if (wait_for(R_INT, INT_BUF_RD | INT_ERR, INT_BUF_RD, 500)) {
		e_rep.last_int = rd(R_INT);
		reset_lines();
		return -3;
	}
	wr(R_INT, INT_BUF_RD);
	for (int i = 0; i < 512; i += 4)
		*(volatile uint32_t *)(out + i) = rd(R_DATA);
	if (wait_for(R_INT, INT_XFER_DONE | INT_ERR, INT_XFER_DONE, 500)) {
		e_rep.last_int = rd(R_INT);
		e_rep.pres = rd(R_PRESENT);
		reset_lines();
		return -4;
	}
	wr(R_INT, INT_XFER_DONE);
	return 0;
}

static int use_adma;
static int read_adma(uint32_t lba, uint32_t nsect);

static int read_pio(uint32_t lba, uint8_t *out)
{
	if (use_adma) {
		int rc = read_adma(lba, 1);
		for (int i = 0; !rc && i < 512; i++)
			out[i] = buf[i];
		return rc;
	}
	return read_pio_cmd(17, lba, out);
}

/* nsect sectors (<=8) via ADMA2 into buf. */
static int read_adma(uint32_t lba, uint32_t nsect)
{
	uint64_t pa = (uint64_t)(uintptr_t)buf;
	adma_tbl[0] = (nsect * 512u << 16) | 0x23;	/* valid | end | tran */
	adma_tbl[1] = (uint32_t)pa;
	wr(R_ADMA_ADDR, (uint32_t)(uintptr_t)adma_tbl);
	wr(R_ADMA_ADDR + 4, 0);
	wr(R_HOSTCTL, (rd(R_HOSTCTL) & ~0x18u) | (2u << 3));		/* ADMA2 32-bit */
	wr(R_BLK, (nsect << 16) | 512);
	uint32_t tm = TM_DMA | TM_READ | (nsect > 1 ? TM_BLKCNT | TM_AUTO12 | TM_MULTI : 0);
	int rc = send(nsect > 1 ? CMD(18, C_R1_DATA) : CMD(17, C_R1_DATA), lba, tm);
	if (rc)
		return rc;
	if (wait_for(R_INT, INT_XFER_DONE | INT_ERR, INT_XFER_DONE, 1000)) {
		e_rep.last_int = rd(R_INT);
		e_rep.pres = rd(R_PRESENT);
		e_rep.adma_err = rd(R_ADMA_ERR);
		reset_lines();
		return -5;
	}
	wr(R_INT, INT_XFER_DONE | INT_DMA);
	return 0;
}


static uint32_t resp[4];

static int cmd(uint32_t idx, uint32_t arg, uint32_t flags)
{
	int rc = send(CMD(idx, flags), arg, 0);
	if (rc)
		return rc;
	for (int i = 0; i < 4; i++)
		resp[i] = rd(R_RESP0 + 4 * i);
	if ((flags & 3) == 3 && wait_for(R_INT, INT_XFER_DONE, INT_XFER_DONE, 1000))	/* R1b busy */
		return -6;
	wr(R_INT, INT_XFER_DONE);
	return 0;
}

static int rd_ext_csd(void)
{
	return read_pio_cmd(8, 0, pio);
}

/* Full eMMC bring-up after the bootloader shut the host down. Returns 0 if the card is in transfer state. */
static int emmc_init(void)
{
	int rc;
	uint32_t ocr = 0;

	set_clock(250);						/* ~400 kHz at a 200 MHz base clock */
	cmd(0, 0, 0);						/* GO_IDLE */
	delay_us(2000);
	for (int i = 0; i < 200; i++) {				/* SEND_OP_COND: sector mode, 1.7-1.95 V + 2.7-3.6 V */
		rc = cmd(1, 0x40ff8080, 0x02);
		if (rc)
			return 10 + rc;
		ocr = resp[0];
		if (ocr & 0x80000000u)
			break;
		delay_us(5000);
	}
	e_rep.ocr = ocr;
	if (!(ocr & 0x80000000u))
		return 20;
	if ((rc = cmd(2, 0, 0x01 | 0x08)))			/* ALL_SEND_CID (R2) */
		return 30 + rc;
	if ((rc = cmd(3, 1u << 16, C_R1)))			/* SET_RELATIVE_ADDR, RCA 1 */
		return 40 + rc;
	if ((rc = cmd(7, 1u << 16, 0x03 | 0x08 | 0x10)))	/* SELECT_CARD (R1b) */
		return 50 + rc;
	set_clock(4);						/* ~25 MHz */
	if ((rc = cmd(6, (3u << 24) | (183u << 16) | (2u << 8) | 1, 0x03 | 0x08 | 0x10)))	/* BUS_WIDTH = 8 bit */
		return 60 + rc;
	wr8(R_HOSTCTL, (uint8_t)(rd(R_HOSTCTL) | 0x20));	/* host: 8-bit bus */
	return 0;
}

static uint32_t le32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }

void test_emmc(void)
{
	con_hex2("EMMC", "ver=", rd(R_VER_SLOT) >> 16, "caps=", rd(R_CAPS));
	con_hex2(" hc", "pres=", rd(R_PRESENT), "hctl=", rd(R_HOSTCTL));
	con_hex2(" hc", "clk=", rd(R_CLK_TOUT_RST) & 0xffff, "int=", rd(R_INT));
	con_hex2(" pwr", "stat=", rd(C_PWR_STATUS), "mask=", rd(C_PWR_MASK));

	/* Stage A: the bootloader only gated the host. Status bits, bus power (1.8 V), SD clock. */
	wr(R_INT_EN, 0xfffffeff);
	wr(0x38, 0);							/* polled: no signals */
	wr(C_PWR_MASK, 0xf);
	wr8(R_HOSTCTL + 1, 0x0b);					/* SD bus power: 1.8 V, on */
	uint32_t seen = pwr_handshake();
	wr8(R_HOSTCTL + 1, 0x0b);
	wr(R_CLK_TOUT_RST, (rd(R_CLK_TOUT_RST) & 0xff00ffff) | (0xeu << 16));	/* max data timeout */
	wr(R_CLK_TOUT_RST, rd(R_CLK_TOUT_RST) | 4);			/* SD clock enable, divider as left */
	delay_us(2000);
	con_hex2(" A pwr", "seen=", seen, "hctl=", rd(R_HOSTCTL));
	con_hex2(" A clk", "clk=", rd(R_CLK_TOUT_RST) & 0xffff, "pres=", rd(R_PRESENT));
	int rc = read_pio(1, pio);
	con_hex2(" A PIO", "rc=", (uint32_t)rc, "last=", e_rep.last_int);

	if (rc) {	/* Stage B: full eMMC initialisation */
		rc = emmc_init();
		con_hex2(" B init", "rc=", (uint32_t)rc, "ocr=", e_rep.ocr);
		con_hex2(" B", "r0=", resp[0], "r1=", resp[1]);
		if (rc)
			return;
		rc = rd_ext_csd();
		con_hex2(" B EXTCSD", "rc=", (uint32_t)rc, "last=", e_rep.last_int);
		con_hex2(" ext", "pres=", e_rep.pres, "w0=", le32(pio));
		con_hex2(" ext", "secs=", le32(pio + 212), "type=", pio[196]);
		/* same sector 0 via ADMA */
		int ra = read_adma(0, 2);
		con_hex2(" B ADMA", "rc=", (uint32_t)ra, "last=", e_rep.last_int);
		con_hex2(" adma", "pres=", e_rep.pres, "aerr=", e_rep.adma_err);
		con_hex2(" adma", "sig=", le32(buf + 512), "sig2=", le32(buf + 516));
		if (!ra) {
			use_adma = 1;
			for (int i = 0; i < 512; i++)
				pio[i] = buf[512 + i];
			rc = 0;
		} else {
			rc = read_pio(1, pio);
			con_hex2(" B PIO", "rc=", (uint32_t)rc, "last=", e_rep.last_int);
		}
	}
	if (rc)
		return;

	con_hex2(" GPT", "sig=", le32(pio), "sig2=", le32(pio + 4));
	if (le32(pio) != 0x20494645 /* "EFI " */) {
		con_str(" GPT", "no EFI PART at LBA1");
		return;
	}
	uint32_t ent_lba = le32(pio + 72), nent = le32(pio + 80), esz = le32(pio + 84);
	con_hex2(" GPT", "ent_lba=", ent_lba, "nent=", nent);

	/* ADMA vs PIO on the same sector (LBA 1, second sector of the buffer). */

	/* Find "userdata": walk the entries 4 per sector with PIO. */
	for (uint32_t i = 0; i < nent && esz == 128; i++) {
		if ((i & 3) == 0 && read_pio(ent_lba + i / 4, pio))
			break;
		const uint8_t *e = pio + (i & 3) * 128;
		static const char want[] = "userdata";
		int m = 1;
		for (int c = 0; c < 9; c++)
			if (e[56 + 2 * c] != (uint8_t)want[c] || e[57 + 2 * c])
				m = 0;
		if (m) {
			con_hex2(" userdata", "first=", le32(e + 32), "last=", le32(e + 40));
			con_hex2(" userdata", "idx=", i, "hi=", le32(e + 36));
			return;
		}
	}
	con_str(" GPT", "userdata not found");
}
