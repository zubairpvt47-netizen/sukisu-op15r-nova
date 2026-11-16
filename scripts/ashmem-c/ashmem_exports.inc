
/* ======================================================================================================
 * Appended by sukisu-op15r-nova (scripts/integrate.sh) - NOT part of Google's ashmem.c.
 *
 * Google's C driver predates the four symbols that the Rust ashmem driver exports for vendor modules
 * (drivers/staging/android/ashmem_exports.c in android16-6.12-2026-03, listed in gki/aarch64/symbols/oplus).
 * These are the same functions with the same prototypes and EXPORT_SYMBOL_GPL, on top of this driver.
 * Semantics follow the Rust driver as fixed upstream in 2026-06 (r54's get_ashmem_area() had the
 * is_ashmem_file() test inverted): non-ashmem file -> -EINVAL / 0 / NULL; ashmem_area_vmfile() returns a
 * new reference that the caller must fput().
 * ====================================================================================================== */
bool is_ashmem_file(struct file *file);
int ashmem_area_name(struct file *file, char *name);
long ashmem_area_size(struct file *file);
struct file *ashmem_area_vmfile(struct file *file);

bool is_ashmem_file(struct file *file)
{
	return file && file->f_op == &ashmem_fops;
}
EXPORT_SYMBOL_GPL(is_ashmem_file);

/* name: at least ASHMEM_FULL_NAME_LEN bytes. "dev/ashmem/<name>", or "dev/ashmem" if no name was set. */
int ashmem_area_name(struct file *file, char *name)
{
	struct ashmem_area *asma;

	if (!name || !is_ashmem_file(file))
		return -EINVAL;

	asma = file->private_data;
	mutex_lock(&ashmem_mutex);
	if (asma->name[ASHMEM_NAME_PREFIX_LEN] != '\0')
		strscpy(name, asma->name, ASHMEM_FULL_NAME_LEN);
	else
		strscpy(name, ASHMEM_NAME_DEF, ASHMEM_FULL_NAME_LEN);
	mutex_unlock(&ashmem_mutex);
	return 0;
}
EXPORT_SYMBOL_GPL(ashmem_area_name);

long ashmem_area_size(struct file *file)
{
	struct ashmem_area *asma;
	long size;

	if (!is_ashmem_file(file))
		return 0;

	asma = file->private_data;
	mutex_lock(&ashmem_mutex);
	size = asma->size;
	mutex_unlock(&ashmem_mutex);
	return size;
}
EXPORT_SYMBOL_GPL(ashmem_area_size);

struct file *ashmem_area_vmfile(struct file *file)
{
	struct ashmem_area *asma;
	struct file *vmfile = NULL;

	if (!is_ashmem_file(file))
		return NULL;

	asma = file->private_data;
	mutex_lock(&ashmem_mutex);
	if (asma->file) {
		get_file(asma->file);
		vmfile = asma->file;
	}
	mutex_unlock(&ashmem_mutex);
	return vmfile;
}
EXPORT_SYMBOL_GPL(ashmem_area_vmfile);
