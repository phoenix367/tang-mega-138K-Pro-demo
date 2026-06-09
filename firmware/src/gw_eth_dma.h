/*
 * gw_eth_dma.h -- register map for the gw_eth_dma engine (eth_dma/rtl/csr.v),
 * EXTS slave at CPU base 0xE8000000.  Matches the Verilog CSR exactly.
 */
#ifndef GW_ETH_DMA_H
#define GW_ETH_DMA_H

#include <stdint.h>

#define ETH_DMA_BASE   0xE8000000u
#define ETH_REG(off)   (*(volatile uint32_t *)(ETH_DMA_BASE + (off)))

#define ETH_CTRL       0x00   /* [0] rx_en  [1] tx_en                         */
#define ETH_IRQ_STAT   0x04   /* W1C [0] rx_done [1] tx_done                  */
#define ETH_IRQ_EN     0x08
#define ETH_RX_BASE    0x10   /* RX ring buffer pool base (phys)             */
#define ETH_RX_LEN     0x14   /* [15:0] number of 2 KB buffers (pow2)        */
#define ETH_RX_TAIL    0x18   /* [15:0] frames consumed by the CPU           */
#define ETH_RX_HEAD    0x1C   /* [15:0] frames written by the DMA (ro)       */
#define ETH_RX_DROP    0x20   /* [15:0] (ro)                                 */
#define ETH_TX_BASE    0x30
#define ETH_TX_LEN     0x34
#define ETH_TX_TAIL    0x38   /* [15:0] frames queued by the CPU             */
#define ETH_TX_HEAD    0x3C   /* [15:0] frames transmitted (ro)              */
#define ETH_TX_FETCH   0x40   /* [15:0] (ro)                                 */
#define ETH_MDIO_ADDR  0x50   /* [4:0] phyad  [9:5] regad                    */
#define ETH_MDIO_WD    0x54   /* [15:0] write data                          */
#define ETH_MDIO_CTRL  0x58   /* write [0]->MDIO read  [1]->MDIO write       */
#define ETH_MDIO_ST    0x5C   /* [15:0] rddata [16] rd_valid [17] busy (ro)  */
#define ETH_MODE       0x60   /* [1:0] 0=10 1=100 2=1000M, [2] full-duplex   */
#define ETH_TX_DBG     0x70   /* [0] TX ahb_master busy, [31:16] cmd_done cnt */
#define ETH_RX_DBG     0x74   /* [0] RX ahb_master busy, [31:16] cmd_done cnt */
#define ETH_EXTM_DBG   0x78   /* [3:0] {hresp, hreadyout, htrans-active, hsel}  */

/* CTRL bits */
#define ETH_CTRL_RX_EN (1u << 0)
#define ETH_CTRL_TX_EN (1u << 1)

/* MDIO_CTRL bits */
#define ETH_MDIO_READ  (1u << 0)
#define ETH_MDIO_WRITE (1u << 1)
/* MDIO_ST bits */
#define ETH_MDIO_RVALID (1u << 16)
#define ETH_MDIO_BUSY   (1u << 17)

/* ETH_MODE encodings */
#define ETH_MODE_1000_FD  ((2u << 0) | (1u << 2))   /* = 6 */
#define ETH_MODE_100_FD   ((1u << 0) | (1u << 2))   /* = 5 */

/* Ring geometry (must match the gateware BUF_SHIFT = 11 -> 2 KB buffers) */
#define ETH_BUF_SIZE   2048u
#define ETH_RING_LEN   4u

#endif /* GW_ETH_DMA_H */
