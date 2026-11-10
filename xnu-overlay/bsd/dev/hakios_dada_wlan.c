/*
 * dada's Wi-Fi for iOS: en0 and the station boundary on top of the ath12k driver (dadawifi=4, hakios_dada_wifi.c).
 *
 * The parts iOS talks to are redwood's: en0 is made by bsd/dev/redwood_net.c, wifid finds it through the registry
 * entries of iokit/Kernel/RedwoodWLAN.cpp, its Apple80211 requests are answered in bsd/dev/redwood_apple80211.c
 * from the station boundary (sys/redwood_sta.h), whose thread is bsd/dev/redwood_sta.c. What is here is the link
 * behind en0 and the station's operations, done with the driver object's station interface (Ath12kWifi's
 * include/nw_abi.h: nw_wifi_scan, nw_wifi_connect, nw_wifi_tx, ...), whose calls only queue a request; the work, and
 * the events that tell its end, happen on the driver's thread (driver() in hakios_dada_wifi.c, nw_wifi_step()).
 *
 *   early      hakios_dada_wlan_early(), at kernel start: en0 is made now, link down, because iOS's Wi-Fi side
 *              looks for the interface and its registry entry once, when it starts, long before the chip's firmware
 *              is up (two minutes into the boot, after Bluetooth and the cold-boot calibration).
 *   address    the interface's and the radio's: boot-arg wifi_mac, else the phone's own (wlan_mac.bin in the small
 *              image's fw/, Android's /mnt/vendor/persist/wlan/wlan_mac.bin), else a made-up local one. The driver
 *              is given the same (plat_fw_get answers wlan_mac.bin with it; mk-ath12k.sh 13 makes the driver use it).
 *   events     hakios_dada_wlan_events(), before the driver starts: scan done, join done, link lost, frames in.
 *              They come on the driver's thread and must not sleep: they set a flag (the station polls it), pass a frame.
 *   station    hakios_dada_wlan_poll(), from the driver's loop: once its interface is up (stage 4) the station
 *              operations are attached, which tells iOS that the radio is on.
 */
#include <kern/clock.h>
#include <kern/kalloc.h>
#include <kern/locks.h>
#include <libkern/libkern.h>
#include <mach/mach_types.h>
#include <pexpert/pexpert.h>
#include <sys/errno.h>
#include <sys/kpi_mbuf.h>
#include <sys/redwood_net.h>
#include <sys/redwood_sta.h>
#include <sys/systm.h>

#define say(...) redwood_tl("dwlan: " __VA_ARGS__)
extern void redwood_tl(const char *format, ...) __printflike(1, 2);
extern const uint8_t *redwood_image_file(const char *dir, const char *name, uint64_t *size, int *disk_out);
extern bool redwood_wifi_radio_address(uint8_t *address);

/* the driver object's station interface (Ath12kWifi include/nw_abi.h; by hand, plain C) -- weak, as in hakios_dada_wifi.c */
struct nw_bss_info {
	uint8_t bssid[6]; uint8_t ssid_len; uint8_t ssid[32];
	uint32_t freq_mhz; int8_t signal_dbm; uint16_t caps, beacon_int; uint32_t age_ms;
	uint16_t ie_len; uint8_t ie[384];
};
enum { NW_STA_OFF, NW_STA_IDLE, NW_STA_SCANNING, NW_STA_AUTH, NW_STA_ASSOC, NW_STA_KEYS, NW_STA_UP };
enum { NW_RES_OK = 0, NW_RES_NOT_FOUND = 1, NW_RES_TIMEOUT = 2, NW_RES_REJECTED = 3, NW_RES_BAD_KEY = 4, NW_RES_UNSUPPORTED = 5,
       NW_RES_FAILED = 6 };
struct nw_wifi_status {
	uint32_t state; int32_t result; uint8_t bssid[6]; uint8_t ssid_len; uint8_t ssid[32]; uint32_t freq_mhz; int8_t signal_dbm;
	uint8_t mac[6]; uint32_t channels;
};
struct nw_wifi_events {
	void (*scan_done)(void);
	void (*connect_done)(int result);
	void (*link_lost)(int reason);
	void (*rx)(const uint8_t *eth, size_t len);
};
struct nw_wifi_stats { uint32_t stage, scans, frames, beacons, bss_seen; int last_err; };
extern struct nw_wifi_stats nw_wifi_stats __attribute__((weak));
extern void nw_wifi_set_events(const struct nw_wifi_events *ev) __attribute__((weak));
extern int nw_wifi_scan(const uint8_t *ssid, size_t len) __attribute__((weak));
extern int nw_wifi_bss_count(void) __attribute__((weak));
extern int nw_wifi_bss_get(int i, struct nw_bss_info *out) __attribute__((weak));
extern int nw_wifi_connect(const uint8_t *ssid, size_t len, const uint8_t *bssid, const char *pass, size_t plen) __attribute__((weak));
extern void nw_wifi_disconnect(void) __attribute__((weak));
extern int nw_wifi_tx(const uint8_t *eth, size_t len) __attribute__((weak));
extern void nw_wifi_status_get(struct nw_wifi_status *st) __attribute__((weak));

static uint8_t wlan_address[6];
static bool wlan_have_address, wlan_early_done, wlan_station_up;

static void
ms(uint32_t n)
{
	delay_for_interval(n, NSEC_PER_MSEC);
}

/* ---- the address ---- */

static int
hexval(uint8_t c)
{
	return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1;
}

/* Android's wlan_mac.bin: lines "Intf0MacAddress=001122334455"; the first interface's */
static bool
address_from_file(uint8_t *a)
{
	uint64_t size = 0;
	const uint8_t *d = redwood_image_file("fw", "wlan_mac.bin", &size, NULL);
	uint64_t at = 0;
	unsigned k = 0;

	if (d == NULL || size == 0) {
		return false;
	}
	while (at < size && d[at] != '=') {
		at++;
	}
	for (at++; at < size && k < 12; at++) {
		int v = hexval(d[at]);

		if (v < 0) {
			break;
		}
		a[k / 2] = (uint8_t)((k & 1) ? (a[k / 2] << 4 | v) : v);
		k++;
	}
	return k == 12 && !(a[0] & 1) && (a[0] | a[1] | a[2] | a[3] | a[4] | a[5]) != 0;
}

/* en0's and the radio's address, the same: decided once */
bool
hakios_dada_wlan_address(uint8_t *address)
{
	if (!wlan_have_address) {
		if (redwood_wifi_radio_address(wlan_address)) {
			say("the radio's address: given (wifi_mac)\n");
		} else if (address_from_file(wlan_address)) {
			say("the radio's address: the phone's own (wlan_mac.bin)\n");
		} else {
			static const uint8_t made[6] = { 0x02, 0xda, 0xda, 0x00, 0x00, 0x01 };

			memcpy(wlan_address, made, 6);
			say("the radio's address: none known, a local one is made (wifi_mac= gives one)\n");
		}
		wlan_have_address = true;
	}
	memcpy(address, wlan_address, 6);
	return true;
}

/* ---- the link behind en0 ---- */

static uint8_t tx_frame[REDWOOD_NET_FRAME_MAX];
static uint64_t tx_frames, tx_dropped, rx_frames;

static bool
link_transmit(mbuf_t packet, size_t length)
{
	if (length > sizeof(tx_frame) || nw_wifi_tx == NULL || mbuf_copydata(packet, 0, length, tx_frame) != 0) {
		tx_dropped++;
		return false;
	}
	if (nw_wifi_tx(tx_frame, length) != 0) {
		tx_dropped++;
		return false;
	}
	tx_frames++;
	return true;
}

static struct redwood_net_link wlan_link = {
	.name = "the phone's radio (ath12k, peach)",
	.wireless = true,
	.up = false,
	.transmit = link_transmit,
};

/* at kernel start (hakios_dada_wifi_init with dadawifi=4): en0 is there before iOS's Wi-Fi side looks */
void
hakios_dada_wlan_early(void)
{
	if (wlan_early_done || nw_wifi_tx == NULL) {
		return;
	}
	wlan_early_done = true;
	(void)hakios_dada_wlan_address(wlan_link.address);
	say("en0 %s\n", redwood_net_attach(&wlan_link) ? "made, the radio behind it (link down until a network is joined)" :
	    "NOT MADE: there is another link behind en0");
}

/* ---- the driver's events (on its thread: no sleeping) ---- */

static volatile int ev_scan_done, ev_join_done, ev_join_result;

static void
ev_scan(void)
{
	ev_scan_done = 1;
}

static void
ev_join(int result)
{
	ev_join_result = result;
	ev_join_done = 1;
	if (result == NW_RES_OK) {
		redwood_net_link_state(true);
	}
}

static void
ev_lost(int reason)
{
	say("the network is lost (%d)\n", reason);
	redwood_net_link_state(false);
	redwood_sta_lost(ECONNRESET);
}

static void
ev_rx(const uint8_t *eth, size_t len)
{
	rx_frames++;
	redwood_net_input(eth, len);
}

static const struct nw_wifi_events wlan_events = { ev_scan, ev_join, ev_lost, ev_rx };

void
hakios_dada_wlan_events(void)
{
	if (nw_wifi_set_events != NULL) {
		nw_wifi_set_events(&wlan_events);
	}
}

/* ---- the station's operations (on redwood_sta.c's thread: they may wait) ---- */

/* wait for a flag an event sets, at most ms milliseconds: true when it was set */
static bool
wait_flag(volatile int *flag, uint32_t most)
{
	for (uint32_t waited = 0; !*flag && waited < most; waited += 20) {
		ms(20);
	}
	return *flag != 0;
}

static int
sta_power(bool on)
{
	if (!on && nw_wifi_disconnect != NULL) {
		nw_wifi_disconnect();
		redwood_net_link_state(false);
	}
	return 0;
}

static int
sta_scan(const struct redwood_sta_scan *what)
{
	ev_scan_done = 0;
	(void)nw_wifi_scan(what != NULL && what->ssid_length ? what->ssid : NULL, what != NULL ? what->ssid_length : 0);
	/* a scan that runs already (the driver's own first one) ends as this one would */
	if (!wait_flag(&ev_scan_done, 15000)) {
		say("a scan did not end in 15 s: what was heard so far is answered\n");
	}
	return 0;
}

static struct redwood_sta_bss heard_one;

static void
sta_heard(void (*each)(const struct redwood_sta_bss *bss, void *context), void *context)
{
	static struct nw_bss_info b;
	int n = nw_wifi_bss_count != NULL ? nw_wifi_bss_count() : 0;

	for (int i = 0; i < n; i++) {
		if (nw_wifi_bss_get(i, &b) != 0) {
			continue;
		}
		bzero(&heard_one, sizeof(heard_one));
		memcpy(heard_one.bssid, b.bssid, 6);
		heard_one.ssid_length = b.ssid_len > 32 ? 32 : b.ssid_len;
		memcpy(heard_one.ssid, b.ssid, heard_one.ssid_length);
		heard_one.frequency = (uint16_t)b.freq_mhz;
		heard_one.rssi = b.signal_dbm;
		heard_one.beacon_interval = b.beacon_int;
		heard_one.capability = b.caps;
		heard_one.age_ms = b.age_ms;
		heard_one.elements_length = b.ie_len > sizeof(b.ie) ? sizeof(b.ie) : b.ie_len;
		memcpy(heard_one.elements, b.ie, heard_one.elements_length);
		each(&heard_one, context);
	}
}

static int
sta_join(const struct redwood_sta_join *what)
{
	static const uint8_t none[6];
	char pass[65];
	size_t plen = 0;
	const uint8_t *bssid = memcmp(what->bssid, none, 6) != 0 ? what->bssid : NULL;

	if (what->security == REDWOOD_STA_WPA2_PSK) {
		if (what->passphrase_length != 0) {
			plen = what->passphrase_length > 63 ? 63 : what->passphrase_length;
			memcpy(pass, what->passphrase, plen);
		} else {
			/* the key itself: 64 hexadecimal digits are taken as the PMK (nw_sta.c) */
			for (int i = 0; i < 32; i++) {
				snprintf(pass + 2 * i, 3, "%02x", what->pmk[i]);
			}
			plen = 64;
		}
		pass[plen] = 0;
	}
	ev_join_done = 0;
	if (nw_wifi_connect(what->ssid, what->ssid_length, bssid, plen ? pass : NULL, plen) != 0) {
		return EIO;
	}
	bzero(pass, sizeof(pass));
	if (!wait_flag(&ev_join_done, 30000)) {
		return ETIMEDOUT;
	}
	switch (ev_join_result) {
	case NW_RES_OK:
		return 0;
	case NW_RES_NOT_FOUND:
		return ENOENT;
	case NW_RES_TIMEOUT:
		return ETIMEDOUT;
	case NW_RES_BAD_KEY:
		return EAUTH;
	case NW_RES_REJECTED:
		return ECONNREFUSED;
	case NW_RES_UNSUPPORTED:
		return ENOTSUP;
	default:
		return EIO;
	}
}

static int
sta_leave(void)
{
	if (nw_wifi_disconnect != NULL) {
		nw_wifi_disconnect();
	}
	redwood_net_link_state(false);
	return 0;
}

static void
sta_state(struct redwood_sta_state *st)
{
	struct nw_wifi_status s;

	bzero(st, sizeof(*st));
	if (nw_wifi_status_get == NULL) {
		return;
	}
	nw_wifi_status_get(&s);
	switch (s.state) {
	case NW_STA_OFF:
		st->phase = REDWOOD_STA_OFF;
		break;
	case NW_STA_IDLE:
		st->phase = REDWOOD_STA_IDLE;
		break;
	case NW_STA_SCANNING:
		st->phase = REDWOOD_STA_SCANNING;
		break;
	case NW_STA_UP:
		st->phase = REDWOOD_STA_JOINED;
		break;
	default:
		st->phase = REDWOOD_STA_JOINING;
		break;
	}
	memcpy(st->bss.bssid, s.bssid, 6);
	st->bss.ssid_length = s.ssid_len > 32 ? 32 : s.ssid_len;
	memcpy(st->bss.ssid, s.ssid, st->bss.ssid_length);
	st->bss.frequency = (uint16_t)s.freq_mhz;
	st->bss.rssi = s.signal_dbm;
}

/* what the radio may tune to: 2.4 GHz 1-13, 5 GHz (52-64 and 100-144 passive, radar); 6 GHz is left out as the station
 * code leaves it out of its scans */
static unsigned
sta_channels(struct redwood_sta_channel *c, unsigned most)
{
	static const uint16_t five[] = { 5180, 5200, 5220, 5240, 5260, 5280, 5300, 5320, 5500, 5520, 5540, 5560, 5580, 5600,
		                         5620, 5640, 5660, 5680, 5700, 5720, 5745, 5765, 5785, 5805, 5825 };
	unsigned n = 0;

	for (unsigned ch = 1; ch <= 13 && n < most; ch++) {
		c[n].frequency = (uint16_t)(2407 + 5 * ch);
		c[n++].flags = 0;
	}
	for (unsigned i = 0; i < sizeof(five) / sizeof(five[0]) && n < most; i++) {
		bool radar = five[i] >= 5260 && five[i] <= 5720;

		c[n].frequency = five[i];
		c[n++].flags = radar ? REDWOOD_STA_CHANNEL_PASSIVE | REDWOOD_STA_CHANNEL_RADAR : 0;
	}
	return n;
}

static struct redwood_sta_ops wlan_ops = {
	.power = sta_power,
	.scan = sta_scan,
	.heard = sta_heard,
	.join = sta_join,
	.leave = sta_leave,
	.state = sta_state,
	.channels = sta_channels,
};

/* from the driver's loop: the station is attached once the driver's interface is up */
void
hakios_dada_wlan_poll(void)
{
	static uint64_t said_at;
	uint64_t now = mach_absolute_time(), ns;

	if (!wlan_station_up && &nw_wifi_stats != NULL && nw_wifi_stats.stage >= 4) {
		wlan_station_up = true;
		(void)hakios_dada_wlan_address(wlan_ops.address);
		redwood_sta_attach(&wlan_ops);
		say("the station is attached: iOS is told the radio is on\n");
	}
	absolutetime_to_nanoseconds(now - said_at, &ns);
	if (wlan_station_up && ns > 30ull * NSEC_PER_SEC) {
		said_at = now;
		say("frames: %llu sent, %llu dropped, %llu received\n", tx_frames, tx_dropped, rx_frames);
	}
}


/*
 * miro/K80 Pro: Wi-Fi is out of scope for this port (no ath12k), so the driver side of every
 * weak nw_wifi_* reference in this file is stubbed here. Nothing calls into them successfully:
 * scan/connect/start all fail, transmit drops, and the statistics block stays zero.
 * The layout mirrors bsd/dev/hakios_dada_wifi.c so that debug prints in that file stay sane.
 */
struct nw_wifi_stats nw_wifi_stats;
volatile uint64_t nw_wifi_where[4] = { 0, 0, 0, 0 };

void nw_wifi_set_events(const struct nw_wifi_events *ev) { (void)ev; }
int  nw_wifi_scan(const uint8_t *ssid, size_t len) { (void)ssid; (void)len; return -1; }
int  nw_wifi_bss_count(void) { return 0; }
int  nw_wifi_bss_get(int i, struct nw_bss_info *out) { (void)i; (void)out; return -1; }
int  nw_wifi_connect(const uint8_t *ssid, size_t len, const uint8_t *bssid,
    const char *pass, size_t plen)
{ (void)ssid; (void)len; (void)bssid; (void)pass; (void)plen; return -1; }
void nw_wifi_disconnect(void) { }
int  nw_wifi_tx(const uint8_t *eth, size_t len) { (void)eth; (void)len; return -1; }
void nw_wifi_status_get(struct nw_wifi_status *st) { if (st) *(int *)st = 0; }
int  nw_wifi_start(const struct lx_platform *p, const struct nw_board *b) { (void)p; (void)b; return -1; }
int  nw_wifi_step(void) { return 0; }
void nw_wifi_stop(void) { }
