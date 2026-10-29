// SPDX-License-Identifier: GPL-2.0
/*
 * Gowin AE350 PT8211 audio -- ALSA playback driver for the audio core in the
 * Tang Mega 138K Pro gateware (audio/rtl; registers at 0xE8002000).
 *
 * The core is a 2048-frame FIFO in front of a serialiser for the Dock's PT8211
 * stereo DAC (16-bit, headphone jack / speaker).  There is no DMA: the ALSA
 * buffer is ordinary vmalloc memory, and the interrupt handler copies frames
 * from it into the FIFO with 32-bit writes ({R, L} = S16_LE interleaved) when
 * the FIFO level drops below a threshold.  So the SoC's missing cache
 * coherence never matters here.  The hardware position (.pointer) is the
 * core's FRAMES register: frames taken from the FIFO since the stream start.
 *
 * Interrupt scheme (the core's IRQ is level-type: level < THRESH):
 *   - normally THRESH = depth/2: the handler fills the FIFO to the top;
 *   - when the buffer has no more frames to push, THRESH = 1 so the handler
 *     runs once more when the FIFO is empty (hw_ptr reaches appl_ptr: ALSA
 *     finishes a drain or reports an xrun) and then masks the interrupt;
 *     CTRL.STOP_EMPTY makes the core stop at that point by itself, so the
 *     interrupt latency does not show up as underrun frames;
 *   - .ack (new data from the application) restores THRESH, clears
 *     STOP_EMPTY and unmasks.
 */
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_irq.h>
#include <linux/irqdomain.h>
#include <linux/io.h>
#include <linux/interrupt.h>
#include <linux/property.h>
#include <linux/math64.h>
#include <sound/core.h>
#include <sound/pcm.h>
#include <sound/pcm_params.h>
#include <sound/initval.h>
#include <sound/info.h>

/* ---- audio core registers (audio/rtl/audio_csr.v) ---- */
#define AUD_CTRL	0x00
#define   CTRL_ENABLE	BIT(0)
#define   CTRL_IRQ_EN	BIT(1)
#define   CTRL_FIFO_RST	BIT(2)
#define   CTRL_SWAP	BIT(3)
#define   CTRL_STOP_EMPTY BIT(4)	/* clear ENABLE at the first empty frame */
#define   CTRL_AMP_EN	BIT(5)	/* headphone amplifier (PA_EN pin), resets to 1 */
#define AUD_STATUS	0x04	/* [15:0] level  [16] level<thresh  [17] full */
#define AUD_DATA	0x08	/* {R, L} */
#define AUD_THRESH	0x0c
#define AUD_RATE	0x10	/* NCO increment: BCK = RATE / 2^32 * bus clock */
#define AUD_UNDERRUN	0x14
#define AUD_OVERRUN	0x18
#define AUD_FRAMES	0x1c
#define AUD_CRC		0x20
#define AUD_DEPTH	0x24
#define AUD_ID		0x2c
#define AUD_ID_VALUE	0x41554430	/* "AUD0" */

static bool swap_lr;
module_param(swap_lr, bool, 0644);
MODULE_PARM_DESC(swap_lr, "send the right channel during WS low (default: left)");

static int hwirq;
module_param(hwirq, int, 0444);
MODULE_PARM_DESC(hwirq, "override the PLIC source number from the device tree (0: use DT). The AE350 maps EXT_INT[0] to PLIC source 4 and EXT_INT[1..15] to 11..25");

struct pt8211 {
	struct device *dev;
	void __iomem *base;
	struct snd_card *card;
	struct snd_pcm *pcm;
	struct snd_pcm_substream *substream;
	spinlock_t lock;
	u32 bus_hz;
	u32 depth;		/* FIFO frames */
	u32 thresh;		/* refill threshold */
	bool running;
	/* stream state (under lock) */
	snd_pcm_uframes_t push_pos;	/* next buffer frame to push */
	snd_pcm_uframes_t pushed;	/* frames pushed since start, mod boundary */
	u32 last_frames;		/* FRAMES at the last period check */
	unsigned long irqs, fills;
};

static const struct snd_pcm_hardware pt8211_hw = {
	.info = SNDRV_PCM_INFO_INTERLEAVED | SNDRV_PCM_INFO_MMAP |
		SNDRV_PCM_INFO_MMAP_VALID,
	.formats = SNDRV_PCM_FMTBIT_S16_LE,
	.rates = SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_11025 | SNDRV_PCM_RATE_16000 |
		 SNDRV_PCM_RATE_22050 | SNDRV_PCM_RATE_32000 | SNDRV_PCM_RATE_44100 |
		 SNDRV_PCM_RATE_48000 | SNDRV_PCM_RATE_96000,
	.rate_min = 8000,
	.rate_max = 96000,
	.channels_min = 2,
	.channels_max = 2,
	.buffer_bytes_max = 256 * 1024,
	.period_bytes_min = 4096,
	.period_bytes_max = 64 * 1024,
	.periods_min = 2,
	.periods_max = 64,
	.fifo_size = 2048 * 4,
};

static inline u32 aud_rd(struct pt8211 *p, u32 off)
{
	return readl(p->base + off);
}

static inline void aud_wr(struct pt8211 *p, u32 off, u32 v)
{
	writel(v, p->base + off);
}

/* CTRL value for a running stream; every CTRL write keeps the amplifier on */
static u32 pt8211_ctrl(struct pt8211 *p)
{
	return CTRL_AMP_EN | CTRL_ENABLE | CTRL_IRQ_EN | (swap_lr ? CTRL_SWAP : 0);
}

/*
 * Push frames from the ALSA buffer (up to appl_ptr) into the FIFO (up to its
 * depth).  Lock held.  Returns true when frames remain to be pushed.
 */
static bool pt8211_fill(struct pt8211 *p)
{
	struct snd_pcm_runtime *rt = p->substream->runtime;
	snd_pcm_uframes_t appl = READ_ONCE(rt->control->appl_ptr);
	snd_pcm_uframes_t avail, n, chunk;
	u32 level = aud_rd(p, AUD_STATUS) & 0xffff;
	u32 room = level < p->depth ? p->depth - level : 0;

	avail = appl >= p->pushed ? appl - p->pushed : appl + rt->boundary - p->pushed;
	n = min_t(snd_pcm_uframes_t, avail, room);
	while (n) {
		chunk = min(n, rt->buffer_size - p->push_pos);
		writesl(p->base + AUD_DATA,
			rt->dma_area + frames_to_bytes(rt, p->push_pos), chunk);
		p->push_pos += chunk;
		if (p->push_pos == rt->buffer_size)
			p->push_pos = 0;
		p->pushed += chunk;
		if (p->pushed >= rt->boundary)
			p->pushed -= rt->boundary;
		avail -= chunk;
		n -= chunk;
	}
	p->fills++;
	return avail != 0;
}

static irqreturn_t pt8211_irq(int irq, void *dev_id)
{
	struct pt8211 *p = dev_id;
	struct snd_pcm_substream *ss;
	bool elapsed = false, more;
	u32 frames, level, ps;

	spin_lock(&p->lock);
	p->irqs++;
	ss = p->substream;
	if (!p->running || !ss) {
		aud_wr(p, AUD_CTRL, (aud_rd(p, AUD_CTRL) & ~CTRL_IRQ_EN) | CTRL_AMP_EN);
		spin_unlock(&p->lock);
		return IRQ_HANDLED;
	}
	more = pt8211_fill(p);
	level = aud_rd(p, AUD_STATUS) & 0xffff;
	if (more) {
		aud_wr(p, AUD_THRESH, p->thresh);
	} else if (level) {
		/* the stream's last frames are in the FIFO: have the core stop
		 * itself when they are out (no underrun count for the tail) and
		 * interrupt once more when empty */
		aud_wr(p, AUD_THRESH, 1);
		aud_wr(p, AUD_CTRL, pt8211_ctrl(p) | CTRL_STOP_EMPTY);
	} else {
		/* everything the application gave us has been played: stop the
		 * serialiser (it would send zeros and count them as underruns
		 * until ALSA stops the stream) and mask; .ack re-enables both */
		aud_wr(p, AUD_CTRL, pt8211_ctrl(p) & ~(CTRL_ENABLE | CTRL_IRQ_EN));
		elapsed = true;
	}
	frames = aud_rd(p, AUD_FRAMES);
	ps = ss->runtime->period_size;
	if (frames / ps != p->last_frames / ps)
		elapsed = true;
	p->last_frames = frames;
	spin_unlock(&p->lock);

	if (elapsed)
		snd_pcm_period_elapsed(ss);
	return IRQ_HANDLED;
}

static int pt8211_open(struct snd_pcm_substream *ss)
{
	struct pt8211 *p = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	int ret;

	rt->hw = pt8211_hw;
	rt->hw.fifo_size = p->depth * 4;
	ret = snd_pcm_hw_constraint_integer(rt, SNDRV_PCM_HW_PARAM_PERIODS);
	if (ret < 0)
		return ret;
	spin_lock_irq(&p->lock);
	p->substream = ss;
	spin_unlock_irq(&p->lock);
	return 0;
}

static int pt8211_close(struct snd_pcm_substream *ss)
{
	struct pt8211 *p = snd_pcm_substream_chip(ss);

	spin_lock_irq(&p->lock);
	p->running = false;
	aud_wr(p, AUD_CTRL, CTRL_AMP_EN);
	p->substream = NULL;
	spin_unlock_irq(&p->lock);
	return 0;
}

static u32 pt8211_rate_inc(struct pt8211 *p, unsigned int rate)
{
	/* inc = rate * 32 * 2^32 / bus_hz, rounded */
	return div_u64(((u64)rate << 37) + p->bus_hz / 2, p->bus_hz);
}

/* ALSA requires .prepare; the real setup happens at the start trigger */
static int pt8211_prepare(struct snd_pcm_substream *ss)
{
	struct pt8211 *p = snd_pcm_substream_chip(ss);
	unsigned long flags;

	spin_lock_irqsave(&p->lock, flags);
	p->running = false;
	aud_wr(p, AUD_CTRL, CTRL_AMP_EN | CTRL_FIFO_RST);
	aud_wr(p, AUD_RATE, pt8211_rate_inc(p, ss->runtime->rate));
	spin_unlock_irqrestore(&p->lock, flags);
	return 0;
}

static int pt8211_trigger(struct snd_pcm_substream *ss, int cmd)
{
	struct pt8211 *p = snd_pcm_substream_chip(ss);
	struct snd_pcm_runtime *rt = ss->runtime;
	unsigned long flags;

	switch (cmd) {
	case SNDRV_PCM_TRIGGER_START:
	case SNDRV_PCM_TRIGGER_RESUME:
		spin_lock_irqsave(&p->lock, flags);
		aud_wr(p, AUD_CTRL, CTRL_AMP_EN | CTRL_FIFO_RST);	/* stop, empty, clear stats */
		aud_wr(p, AUD_RATE, pt8211_rate_inc(p, rt->rate));
		aud_wr(p, AUD_THRESH, p->thresh);
		p->push_pos = 0;
		p->pushed = 0;
		p->last_frames = 0;
		p->running = true;
		pt8211_fill(p);
		aud_wr(p, AUD_CTRL, pt8211_ctrl(p));
		spin_unlock_irqrestore(&p->lock, flags);
		return 0;
	case SNDRV_PCM_TRIGGER_STOP:
	case SNDRV_PCM_TRIGGER_SUSPEND:
		spin_lock_irqsave(&p->lock, flags);
		p->running = false;
		/* stop + mask; the FIFO and the FRAMES/CRC/UNDERRUN/OVERRUN
		 * statistics stay readable until the next start */
		aud_wr(p, AUD_CTRL, CTRL_AMP_EN);
		spin_unlock_irqrestore(&p->lock, flags);
		return 0;
	default:
		return -EINVAL;
	}
}

static snd_pcm_uframes_t pt8211_pointer(struct snd_pcm_substream *ss)
{
	struct pt8211 *p = snd_pcm_substream_chip(ss);

	return aud_rd(p, AUD_FRAMES) % ss->runtime->buffer_size;
}

/* the application advanced appl_ptr: make sure the refill interrupt is live */
static int pt8211_ack(struct snd_pcm_substream *ss)
{
	struct pt8211 *p = snd_pcm_substream_chip(ss);
	unsigned long flags;

	spin_lock_irqsave(&p->lock, flags);
	if (p->running) {
		aud_wr(p, AUD_THRESH, p->thresh);
		aud_wr(p, AUD_CTRL, pt8211_ctrl(p));
	}
	spin_unlock_irqrestore(&p->lock, flags);
	return 0;
}

static const struct snd_pcm_ops pt8211_ops = {
	.open = pt8211_open,
	.close = pt8211_close,
	.prepare = pt8211_prepare,
	.trigger = pt8211_trigger,
	.pointer = pt8211_pointer,
	.ack = pt8211_ack,
};

static void pt8211_proc_read(struct snd_info_entry *entry,
			     struct snd_info_buffer *buffer)
{
	struct pt8211 *p = entry->private_data;

	snd_iprintf(buffer, "ctrl 0x%x status 0x%x thresh %u rate 0x%08x\n",
		    aud_rd(p, AUD_CTRL), aud_rd(p, AUD_STATUS),
		    aud_rd(p, AUD_THRESH), aud_rd(p, AUD_RATE));
	snd_iprintf(buffer, "frames %u crc 0x%08x underrun %u overrun %u\n",
		    aud_rd(p, AUD_FRAMES), aud_rd(p, AUD_CRC),
		    aud_rd(p, AUD_UNDERRUN), aud_rd(p, AUD_OVERRUN));
	snd_iprintf(buffer, "irqs %lu fills %lu depth %u bus %u Hz\n",
		    p->irqs, p->fills, p->depth, p->bus_hz);
}

static int pt8211_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct snd_card *card;
	struct pt8211 *p;
	struct snd_pcm *pcm;
	int irq, ret;
	u32 id;

	ret = snd_devm_card_new(dev, SNDRV_DEFAULT_IDX1, "PT8211", THIS_MODULE,
				sizeof(*p), &card);
	if (ret < 0)
		return ret;
	p = card->private_data;
	p->dev = dev;
	p->card = card;
	spin_lock_init(&p->lock);

	p->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(p->base))
		return PTR_ERR(p->base);
	id = aud_rd(p, AUD_ID);
	if (id != AUD_ID_VALUE) {
		dev_err(dev, "no audio core (ID 0x%08x)\n", id);
		return -ENODEV;
	}
	p->depth = aud_rd(p, AUD_DEPTH) & 0xffff;
	if (!p->depth)
		p->depth = 2048;
	p->thresh = p->depth / 2;
	p->bus_hz = 50000000;
	device_property_read_u32(dev, "clock-frequency", &p->bus_hz);
	/* amplifier on from here (not toggled per stream: that would pop) */
	aud_wr(p, AUD_CTRL, CTRL_AMP_EN | CTRL_FIFO_RST);

	if (hwirq > 0) {
		/* the interrupt line's PLIC source, bypassing the DT 'interrupts' */
		struct device_node *parent = of_irq_find_parent(dev->of_node);
		struct irq_fwspec fwspec = {
			.fwnode = of_node_to_fwnode(parent),
			.param_count = 2,
			.param = { hwirq, IRQ_TYPE_LEVEL_HIGH },
		};
		irq = parent ? irq_create_fwspec_mapping(&fwspec) : 0;
		of_node_put(parent);
		if (irq <= 0)
			return -ENXIO;
		dev_info(dev, "using PLIC source %d (module parameter)\n", hwirq);
	} else {
		irq = platform_get_irq(pdev, 0);
		if (irq < 0)
			return irq;
	}
	ret = devm_request_irq(dev, irq, pt8211_irq, 0, dev_name(dev), p);
	if (ret)
		return ret;

	ret = snd_pcm_new(card, "PT8211", 0, 1, 0, &pcm);
	if (ret < 0)
		return ret;
	p->pcm = pcm;
	pcm->private_data = p;
	strscpy(pcm->name, "PT8211 DAC", sizeof(pcm->name));
	snd_pcm_set_ops(pcm, SNDRV_PCM_STREAM_PLAYBACK, &pt8211_ops);
	snd_pcm_set_managed_buffer_all(pcm, SNDRV_DMA_TYPE_VMALLOC, NULL,
				       64 * 1024, 256 * 1024);

	strscpy(card->driver, "gowin-pt8211", sizeof(card->driver));
	strscpy(card->shortname, "PT8211", sizeof(card->shortname));
	snprintf(card->longname, sizeof(card->longname),
		 "Gowin AE350 PT8211 audio at %pa irq %d", &pdev->resource[0].start, irq);
	snd_card_ro_proc_new(card, "pt8211", p, pt8211_proc_read);

	ret = snd_card_register(card);
	if (ret < 0)
		return ret;
	platform_set_drvdata(pdev, p);
	dev_info(dev, "PT8211 audio: FIFO %u frames, bus %u Hz, irq %d\n",
		 p->depth, p->bus_hz, irq);
	return 0;
}

static void pt8211_remove(struct platform_device *pdev)
{
	struct pt8211 *p = platform_get_drvdata(pdev);

	aud_wr(p, AUD_CTRL, 0);		/* serialiser, interrupt and amplifier off */
}

static const struct of_device_id pt8211_of_match[] = {
	{ .compatible = "gowin,ae350-pt8211" },
	{ }
};
MODULE_DEVICE_TABLE(of, pt8211_of_match);

static struct platform_driver pt8211_driver = {
	.probe = pt8211_probe,
	.remove = pt8211_remove,
	.driver = {
		.name = "gowin-pt8211",
		.of_match_table = pt8211_of_match,
	},
};
module_platform_driver(pt8211_driver);

MODULE_DESCRIPTION("Gowin AE350 PT8211 audio output (FIFO, no DMA)");
MODULE_LICENSE("GPL");
