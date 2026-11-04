/* osd.h -- vidplay's info bar on the LCD core's OSD layer (osd.c) */
#ifndef OSD_H
#define OSD_H
int  osd_init(int fb_fd, unsigned panel_w, unsigned panel_h);   /* -1: no OSD in this gateware/kernel */
void osd_update(int visible, const char *title, double pos, double dur);   /* redraws only on change */
void osd_close(void);
#endif
