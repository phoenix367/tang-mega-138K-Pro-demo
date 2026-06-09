// SPDX-License-Identifier: GPL-2.0
/*
 * Gowin Triple-Speed Ethernet MAC -- PIO (no-DMA) netdev driver
 * for the AE350 SoC on the Tang Mega 138K Pro Dock.
 *
 * The MAC exposes a single 1536-byte frame window (TX on write / RX on read)
 * plus length/enable/irq and an MDIO (MIIM) block, all on the SoC's external
 * AHB-slave port at 0xE8000000. There are NO DMA descriptor rings -- the CPU
 * copies each frame through the register window -- so this driver is immune to
 * the SoC's missing-coherence-manager problem (see CACHE_ISSUES.md). Throughput
 * is modest (one CPU-copied frame at a time); fine for management/control.
 *
 * Register map (from the SDK bare-metal ethernet.h):
 *   0x000..0x5FF  frame window: ETH_TX_DATA[384] (W) / ETH_RX_DATA[384] (R)
 *   0x600 TX_LENGTH[10:0]  0x604 TX_EN[0]  0x608 TX_FAIL[2:0]
 *   0x60C TX_IS  0x610 TX_IC  0x614 TX_IE          (all bit0)
 *   0x680 RX_LENGTH  0x684 RX_IS  0x688 RX_IE  0x68C RX_IC
 *   0x700 MIIM_OP_MODE(0=wr,1=rd) 0x704 PHYAD[4:0] 0x708 REGAD[4:0]
 *   0x70C MIIM_WRDATA 0x710 MIIM_RDDATA 0x714 MIIM_IS(b1 op-end,b0 rd-valid)
 *   0x718 MIIM_IE 0x71C MIIM_IC 0x720 MIIM_OP_EN[0]
 *   0x724 ETH_MODE: [1:0] speed(0=100,1=1000,2=10), bit2=half-duplex
 *
 * Devicetree (drop into the SoC node):
 *   ethernet@e8000000 {
 *       compatible  = "gowin,ae350-tse";
 *       reg         = <0xe8000000 0x800>;
 *       interrupt-parent = <&plic>;
 *       interrupts  = <4>;                 // EXT_INT[0] == GP0 == PLIC src 4
 *       phy-mode    = "rgmii-id";          // PHY supplies the RGMII delay
 *       phy-handle  = <&phy0>;
 *       mdio {
 *           #address-cells = <1>;
 *           #size-cells = <0>;
 *           phy0: ethernet-phy@0 { reg = <0>; };   // RTL8211-class, MDIO addr 0
 *       };
 *   };
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/netdevice.h>
#include <linux/etherdevice.h>
#include <linux/interrupt.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/of.h>
#include <linux/of_mdio.h>
#include <linux/of_net.h>
#include <linux/phy.h>
#include <linux/bitops.h>
#include <linux/unaligned.h>

#define GTSE_FRAME_MAX		1536

#define GTSE_TX_DATA		0x000	/* and RX_DATA -- same window */
#define GTSE_TX_LENGTH		0x600
#define GTSE_TX_EN		0x604
#define GTSE_TX_FAIL		0x608
#define GTSE_TX_IS		0x60c
#define GTSE_TX_IC		0x610
#define GTSE_TX_IE		0x614
#define GTSE_RX_LENGTH		0x680
#define GTSE_RX_IS		0x684
#define GTSE_RX_IE		0x688
#define GTSE_RX_IC		0x68c
#define GTSE_MIIM_OP_MODE	0x700
#define GTSE_MIIM_PHYAD		0x704
#define GTSE_MIIM_REGAD		0x708
#define GTSE_MIIM_WRDATA	0x70c
#define GTSE_MIIM_RDDATA	0x710
#define GTSE_MIIM_IS		0x714
#define GTSE_MIIM_IE		0x718
#define GTSE_MIIM_IC		0x71c
#define GTSE_MIIM_OP_EN		0x720
#define GTSE_ETH_MODE		0x724

#define GTSE_IRQ_BIT		BIT(0)
#define MIIM_OP_READ		0	/* per bare-metal: OP_MODE 0 = read */
#define MIIM_OP_WRITE		1	/*                 OP_MODE 1 = write */
#define MIIM_IS_OPEND		BIT(1)
#define MIIM_IS_RDVALID		BIT(0)
#define ETH_MODE_100		0u
#define ETH_MODE_1000		1u
#define ETH_MODE_10		2u
#define ETH_MODE_HALF		BIT(2)

struct gtse_priv {
	void __iomem *base;
	struct net_device *ndev;
	struct device *dev;
	struct mii_bus *mii;
	int irq;
	spinlock_t lock;	/* serialises the single frame window + MIIM */
};

static inline u32 gtse_rd(struct gtse_priv *p, u32 off)
{
	return ioread32(p->base + off);
}
static inline void gtse_wr(struct gtse_priv *p, u32 off, u32 val)
{
	iowrite32(val, p->base + off);
}

/* ------------------------------------------------------------------ MDIO */
static int gtse_mdio_read(struct mii_bus *bus, int phy, int reg)
{
	struct gtse_priv *p = bus->priv;
	u32 v;
	int ret;

	gtse_wr(p, GTSE_MIIM_PHYAD, phy & 0x1f);
	gtse_wr(p, GTSE_MIIM_REGAD, reg & 0x1f);
	gtse_wr(p, GTSE_MIIM_OP_MODE, MIIM_OP_READ);
	gtse_wr(p, GTSE_MIIM_IC, MIIM_IS_OPEND | MIIM_IS_RDVALID);
	gtse_wr(p, GTSE_MIIM_OP_EN, 1);

	ret = readl_poll_timeout(p->base + GTSE_MIIM_IS, v,
				 v & MIIM_IS_RDVALID, 5, 10000);
	if (ret)
		return ret;
	v = gtse_rd(p, GTSE_MIIM_RDDATA) & 0xffff;
	gtse_wr(p, GTSE_MIIM_IC, MIIM_IS_OPEND | MIIM_IS_RDVALID);
	return v;
}

static int gtse_mdio_write(struct mii_bus *bus, int phy, int reg, u16 val)
{
	struct gtse_priv *p = bus->priv;
	u32 v;
	int ret;

	gtse_wr(p, GTSE_MIIM_PHYAD, phy & 0x1f);
	gtse_wr(p, GTSE_MIIM_REGAD, reg & 0x1f);
	gtse_wr(p, GTSE_MIIM_WRDATA, val);
	gtse_wr(p, GTSE_MIIM_OP_MODE, MIIM_OP_WRITE);
	gtse_wr(p, GTSE_MIIM_IC, MIIM_IS_OPEND | MIIM_IS_RDVALID);
	gtse_wr(p, GTSE_MIIM_OP_EN, 1);

	ret = readl_poll_timeout(p->base + GTSE_MIIM_IS, v,
				 v & MIIM_IS_OPEND, 5, 10000);
	gtse_wr(p, GTSE_MIIM_IC, MIIM_IS_OPEND | MIIM_IS_RDVALID);
	return ret;
}

/* ------------------------------------------------------------------ link */
static void gtse_adjust_link(struct net_device *ndev)
{
	struct gtse_priv *p = netdev_priv(ndev);
	struct phy_device *phy = ndev->phydev;
	u32 mode;

	if (!phy->link)
		return;

	switch (phy->speed) {
	case SPEED_1000: mode = ETH_MODE_1000; break;
	case SPEED_10:   mode = ETH_MODE_10;   break;
	default:         mode = ETH_MODE_100;  break;
	}
	if (phy->duplex != DUPLEX_FULL)
		mode |= ETH_MODE_HALF;

	gtse_wr(p, GTSE_ETH_MODE, mode);
	phy_print_status(phy);
}

/* -------------------------------------------------------------------- RX */
static void gtse_rx_one(struct net_device *ndev)
{
	struct gtse_priv *p = netdev_priv(ndev);
	u32 len = gtse_rd(p, GTSE_RX_LENGTH) & 0x7ff;
	unsigned int i, words;
	struct sk_buff *skb;
	u8 *dst;

	if (!len || len > GTSE_FRAME_MAX) {
		ndev->stats.rx_length_errors++;
		goto ack;
	}
	/* allocate rounded up so the final word write stays in-bounds */
	skb = netdev_alloc_skb_ip_align(ndev, ALIGN(len, 4));
	if (!skb) {
		ndev->stats.rx_dropped++;
		goto ack;
	}
	words = DIV_ROUND_UP(len, 4);
	dst = skb_put(skb, words * 4);		/* trimmed back to len below */
	for (i = 0; i < words; i++)
		put_unaligned_le32(gtse_rd(p, GTSE_TX_DATA + i * 4), dst + i * 4);
	skb_trim(skb, len);

	skb->protocol = eth_type_trans(skb, ndev);
	ndev->stats.rx_packets++;
	ndev->stats.rx_bytes += len;
	netif_rx(skb);
ack:
	gtse_wr(p, GTSE_RX_IC, GTSE_IRQ_BIT);
}

/* -------------------------------------------------------------------- TX */
static netdev_tx_t gtse_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct gtse_priv *p = netdev_priv(ndev);
	unsigned int len, words, i;
	unsigned long flags;

	len = skb->len;
	if (len > GTSE_FRAME_MAX) {
		ndev->stats.tx_dropped++;
		dev_kfree_skb_any(skb);
		return NETDEV_TX_OK;
	}
	/* pad so the last 32-bit copy reads a full word from skb->data */
	if (skb_padto(skb, ALIGN(len, 4)))
		return NETDEV_TX_OK;		/* skb already freed */
	words = DIV_ROUND_UP(len, 4);

	spin_lock_irqsave(&p->lock, flags);

	/* single frame buffer: don't accept another until this one drains */
	if (gtse_rd(p, GTSE_TX_EN) & GTSE_IRQ_BIT) {
		spin_unlock_irqrestore(&p->lock, flags);
		netif_stop_queue(ndev);
		return NETDEV_TX_BUSY;
	}

	for (i = 0; i < words; i++)
		gtse_wr(p, GTSE_TX_DATA + i * 4,
			get_unaligned_le32(skb->data + i * 4));
	gtse_wr(p, GTSE_TX_LENGTH, len);
	gtse_wr(p, GTSE_TX_EN, GTSE_IRQ_BIT);	/* kick */

	netif_stop_queue(ndev);			/* TX irq re-wakes it */
	spin_unlock_irqrestore(&p->lock, flags);

	ndev->stats.tx_packets++;
	ndev->stats.tx_bytes += len;
	dev_kfree_skb_any(skb);			/* MAC has its own copy */
	return NETDEV_TX_OK;
}

/* ------------------------------------------------------------------- IRQ */
static irqreturn_t gtse_isr(int irq, void *dev_id)
{
	struct net_device *ndev = dev_id;
	struct gtse_priv *p = netdev_priv(ndev);
	irqreturn_t handled = IRQ_NONE;

	if (gtse_rd(p, GTSE_RX_IS) & GTSE_IRQ_BIT) {
		gtse_rx_one(ndev);
		handled = IRQ_HANDLED;
	}
	if (gtse_rd(p, GTSE_TX_IS) & GTSE_IRQ_BIT) {
		gtse_wr(p, GTSE_TX_IC, GTSE_IRQ_BIT);
		if (gtse_rd(p, GTSE_TX_FAIL))
			ndev->stats.tx_errors++;
		if (netif_queue_stopped(ndev))
			netif_wake_queue(ndev);
		handled = IRQ_HANDLED;
	}
	return handled;
}

/* ---------------------------------------------------------------- open/stop */
static int gtse_open(struct net_device *ndev)
{
	struct gtse_priv *p = netdev_priv(ndev);
	int ret;

	ret = request_irq(p->irq, gtse_isr, 0, ndev->name, ndev);
	if (ret)
		return ret;

	gtse_wr(p, GTSE_RX_IC, GTSE_IRQ_BIT);
	gtse_wr(p, GTSE_TX_IC, GTSE_IRQ_BIT);
	gtse_wr(p, GTSE_RX_IE, GTSE_IRQ_BIT);
	gtse_wr(p, GTSE_TX_IE, GTSE_IRQ_BIT);

	phy_start(ndev->phydev);
	netif_start_queue(ndev);
	return 0;
}

static int gtse_stop(struct net_device *ndev)
{
	struct gtse_priv *p = netdev_priv(ndev);

	netif_stop_queue(ndev);
	phy_stop(ndev->phydev);
	gtse_wr(p, GTSE_RX_IE, 0);
	gtse_wr(p, GTSE_TX_IE, 0);
	free_irq(p->irq, ndev);
	return 0;
}

static const struct net_device_ops gtse_netdev_ops = {
	.ndo_open		= gtse_open,
	.ndo_stop		= gtse_stop,
	.ndo_start_xmit		= gtse_start_xmit,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
};

/* ----------------------------------------------------------- probe/remove */
static int gtse_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *mdio_np, *phy_np;
	struct net_device *ndev;
	struct gtse_priv *p;
	int ret;

	ndev = devm_alloc_etherdev(dev, sizeof(*p));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);

	p = netdev_priv(ndev);
	p->ndev = ndev;
	p->dev = dev;
	spin_lock_init(&p->lock);

	p->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);

	p->irq = platform_get_irq(pdev, 0);
	if (p->irq < 0)
		return p->irq;

	if (of_get_ethdev_address(dev->of_node, ndev))
		eth_hw_addr_random(ndev);

	ndev->netdev_ops = &gtse_netdev_ops;
	ndev->irq = p->irq;
	ndev->mtu = ETH_DATA_LEN;		/* PIO window holds one MTU frame */

	/* ---- MDIO bus ---- */
	p->mii = devm_mdiobus_alloc(dev);
	if (!p->mii)
		return -ENOMEM;
	p->mii->name = "gtse-mii";
	p->mii->read = gtse_mdio_read;
	p->mii->write = gtse_mdio_write;
	p->mii->priv = p;
	p->mii->parent = dev;
	snprintf(p->mii->id, MII_BUS_ID_SIZE, "%s", dev_name(dev));

	mdio_np = of_get_child_by_name(dev->of_node, "mdio");
	ret = of_mdiobus_register(p->mii, mdio_np);
	of_node_put(mdio_np);
	if (ret)
		return dev_err_probe(dev, ret, "MDIO register failed\n");

	/* ---- connect the PHY (RGMII-ID: delay is in the PHY) ---- */
	phy_np = of_parse_phandle(dev->of_node, "phy-handle", 0);
	if (!phy_np) {
		ret = -ENODEV;
		goto err_mdio;
	}
	ndev->phydev = of_phy_connect(ndev, phy_np, gtse_adjust_link, 0,
				      PHY_INTERFACE_MODE_RGMII_ID);
	of_node_put(phy_np);
	if (!ndev->phydev) {
		ret = -ENODEV;
		goto err_mdio;
	}

	ret = register_netdev(ndev);
	if (ret)
		goto err_phy;

	netdev_info(ndev, "Gowin TSE (PIO) at %pa, irq %d\n",
		    &pdev->resource[0].start, p->irq);
	return 0;

err_phy:
	phy_disconnect(ndev->phydev);
err_mdio:
	mdiobus_unregister(p->mii);
	return ret;
}

static void gtse_remove(struct platform_device *pdev)
{
	struct net_device *ndev = platform_get_drvdata(pdev);
	struct gtse_priv *p = netdev_priv(ndev);

	unregister_netdev(ndev);
	phy_disconnect(ndev->phydev);
	mdiobus_unregister(p->mii);
}

static const struct of_device_id gtse_of_match[] = {
	{ .compatible = "gowin,ae350-tse" },
	{ }
};
MODULE_DEVICE_TABLE(of, gtse_of_match);

static struct platform_driver gtse_driver = {
	.probe	= gtse_probe,
	.remove	= gtse_remove,
	.driver	= {
		.name		= "gw-tse",
		.of_match_table	= gtse_of_match,
	},
};
module_platform_driver(gtse_driver);

MODULE_DESCRIPTION("Gowin Triple-Speed Ethernet (PIO) for AE350");
MODULE_LICENSE("GPL");
