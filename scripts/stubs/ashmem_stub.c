// SPDX-License-Identifier: GPL-2.0
/*
 * Stand-ins for the four symbols the Rust ashmem driver exports (drivers/staging/android/ashmem_exports.c).
 *
 * With any LTO mode Kconfig turns Rust off (RUST depends on !DEBUG_INFO_BTF || (PAHOLE_HAS_LANG_EXCLUDE && !LTO), and
 * BTF stays on for eBPF), and ASHMEM depends on RUST, so the driver is not built. The OnePlus vendor modules are
 * compiled against these symbols (gki/aarch64/symbols/oplus), and Kleaf's kmi_symbol_list_strict_mode requires them
 * in the ksymtab. Without the driver there are no ashmem files, so "not an ashmem file" is the correct answer.
 *
 * Only built when CONFIG_ASHMEM is not set (kernel/Makefile guard added by scripts/integrate.sh).
 */
#include <linux/err.h>
#include <linux/errno.h>
#include <linux/export.h>
#include <linux/fs.h>
#include <linux/types.h>

bool is_ashmem_file(struct file *file);
int ashmem_area_name(struct file *file, char *name);
long ashmem_area_size(struct file *file);
struct file *ashmem_area_vmfile(struct file *file);

bool is_ashmem_file(struct file *file)
{
	return false;
}
EXPORT_SYMBOL_GPL(is_ashmem_file);

int ashmem_area_name(struct file *file, char *name)
{
	return -EINVAL;
}
EXPORT_SYMBOL_GPL(ashmem_area_name);

long ashmem_area_size(struct file *file)
{
	return -EINVAL;
}
EXPORT_SYMBOL_GPL(ashmem_area_size);

struct file *ashmem_area_vmfile(struct file *file)
{
	return NULL;
}
EXPORT_SYMBOL_GPL(ashmem_area_vmfile);
