#!/bin/bash
# Hybrid U-Boot: runtime DRAM type probe (LPDDR4 -> LPDDR3 -> DDR3) in SPL.
set -euo pipefail
cd ~/work/build/u-boot-2026.01
F=arch/arm/mach-sunxi/dram_sun50i_h616.c
K=arch/arm/mach-sunxi/Kconfig

# backup once
[ -f $F.hybrid.bak ] || cp $F $F.hybrid.bak
cp $F.hybrid.bak $F
git checkout -- $K 2>/dev/null || true

# 1) Kconfig: add H616 AUTO choice entry after DDR3_1333 block
python3 - <<'EOF'
import re
k=open('arch/arm/mach-sunxi/Kconfig').read()
if 'SUNXI_DRAM_H616_AUTO' not in k:
    ins='''
config SUNXI_DRAM_H616_AUTO
	bool "Auto-detect LPDDR4/LPDDR3/DDR3 on the H616 DRAM controller"
	depends on DRAM_SUN50I_H616
	help
	  Probe DRAM types at boot and use the first that trains.

'''
    m=re.search(r'(config SUNXI_DRAM_H616_LPDDR4\n(?:[^\n]*\n)*?)(config )', k)
    k=k.replace('config SUNXI_DRAM_H616_LPDDR4\n', 'config SUNXI_DRAM_H616_AUTO\n\tbool "Auto-detect LPDDR4/LPDDR3/DDR3 on the H616 DRAM controller"\n\tselect SUNXI_DRAM_LPDDR4\n\tdepends on DRAM_SUN50I_H616\n\thelp\n\t  Probe candidate DRAM types at boot and use the first that trains.\n\nconfig SUNXI_DRAM_H616_LPDDR4\n',1)
    open('arch/arm/mach-sunxi/Kconfig','w').write(k)
EOF

# 2) dram_para: keep static defaults; type set by probe when AUTO
python3 - <<'EOF'
f='arch/arm/mach-sunxi/dram_sun50i_h616.c'
s=open(f).read()

probe='''
struct dram_type_para {
	enum sunxi_dram_type type;
	u32 tpr0;
	u32 tpr2;
};

#if defined(CONFIG_SUNXI_DRAM_H616_AUTO)
static const struct dram_type_para dram_type_params[] = {
	{ SUNXI_DRAM_TYPE_LPDDR4, CONFIG_DRAM_SUNXI_TPR0, CONFIG_DRAM_SUNXI_TPR2 },
	{ SUNXI_DRAM_TYPE_LPDDR3, 0, 0 },
	{ SUNXI_DRAM_TYPE_DDR3, 0, 1 },
};
#endif

static const struct dram_type_para *mctl_probe_dram_type(struct dram_para *probe)
{
#if defined(CONFIG_SUNXI_DRAM_H616_AUTO)
	struct dram_config config;
	size_t i;

	for (i = 0; i < ARRAY_SIZE(dram_type_params); i++) {
		probe->type = dram_type_params[i].type;
		probe->tpr0 = dram_type_params[i].tpr0;
		probe->tpr2 = dram_type_params[i].tpr2;
		if (mctl_core_init(probe, &config))
			return &dram_type_params[i];
	}
	panic("No compatible DRAM type detected.\\n");
#endif
	return NULL;
}

'''

s=s.replace('static const struct dram_para para = {', probe+'static struct dram_para para = {',1)
s=s.replace('const struct dram_para para = {','struct dram_para para = {',1)

# in AUTO mode set initial tpr0/tpr2 from LPDDR4 defaults already in para; nothing more
old_init='''	setbits_le32(prcm + CCU_PRCM_RES_CAL_CTRL, BIT(8));
	clrbits_le32(prcm + CCU_PRCM_OHMS240, 0x3f);

	mctl_auto_detect_rank_width(&para, &config);'''
new_init='''	setbits_le32(prcm + CCU_PRCM_RES_CAL_CTRL, BIT(8));
	clrbits_le32(prcm + CCU_PRCM_OHMS240, 0x3f);

#if defined(CONFIG_SUNXI_DRAM_H616_AUTO)
	{
		const struct dram_type_para *tp = mctl_probe_dram_type(&para);

		printf("DRAM:  probe type=%d\\n", tp->type);
	}
#endif

	mctl_auto_detect_rank_width(&para, &config);'''
assert old_init in s
s=s.replace(old_init,new_init,1)
open(f,'w').write(s)
EOF

# 3) defconfig hybrid on top of lpddr4 config (LPDDR4 timing defaults)
make anbernic_rg35xx_h700_lpddr4_defconfig >/dev/null
sed -i 's/^CONFIG_SUNXI_DRAM_H616_LPDDR4=y/# CONFIG_SUNXI_DRAM_H616_LPDDR4 is not set/' .config
grep -q SUNXI_DRAM_H616_AUTO .config || echo "CONFIG_SUNXI_DRAM_H616_AUTO=y" >> .config
make olddefconfig >/dev/null
grep -E "SUNXI_DRAM_H616" .config

# 4) build
export BL31=$HOME/work/build/atf/build/sun50i_h616/release/bl31.bin
make -j14 2>&1 | tail -3
ls -la u-boot-sunxi-with-spl.bin
cp u-boot-sunxi-with-spl.bin ~/work/out/u-boot-sunxi-with-spl-hybrid.bin
echo DONE_HYBRID_UBOOT
