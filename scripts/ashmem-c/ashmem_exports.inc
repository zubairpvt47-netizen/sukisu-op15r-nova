
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

/* ======================================================================================================
 * ashmem ioctls on memfd files. android16-6.12-2026-03's mm/shmem.c points shmem_file_operations at
 * ashmem_memfd_ioctl() when CONFIG_ASHMEM is set (Android's ashmem -> memfd migration: libcutils may hand out a
 * memfd where the caller expects an ashmem fd). Google's C driver predates this, so it is ported here from the
 * Rust driver (ashmem.rs, ashmem_memfd_ioctl) case by case.
 * ====================================================================================================== */
#include <linux/capability.h>
#include <linux/fcntl.h>
#include <linux/memfd.h>

long ashmem_memfd_ioctl(struct file *file, unsigned int cmd, unsigned long arg);

#define ASHMEM_MEMFD_WRITE_SEALS	(F_SEAL_WRITE | F_SEAL_FUTURE_WRITE)

long ashmem_memfd_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	long seals, ret;
	unsigned long prot;
	bool is_writable;

#ifdef CONFIG_COMPAT
	switch (cmd) {
	case COMPAT_ASHMEM_SET_SIZE:
		cmd = ASHMEM_SET_SIZE;
		break;
	case COMPAT_ASHMEM_SET_PROT_MASK:
		cmd = ASHMEM_SET_PROT_MASK;
		break;
	case COMPAT_ASHMEM_GET_FILE_ID: {
		u32 ino32 = file_inode(file)->i_ino;

		if (put_user(ino32, (u32 __user *)compat_ptr(arg)))
			return -EFAULT;
		return 0;
	}
	}
#endif

	switch (cmd) {
	case ASHMEM_GET_NAME: {
		const struct qstr *q = &file->f_path.dentry->d_name;
		const char *n = q->name;
		size_t len = q->len;
		char local_name[ASHMEM_NAME_LEN] = {};

		/* memfd stores "memfd:<name>"; ashmem callers expect just <name> */
		if (len >= 6 && !memcmp(n, "memfd:", 6)) {
			n += 6;
			len -= 6;
		}
		len = min_t(size_t, len, ASHMEM_NAME_LEN);
		memcpy(local_name, n, len);
		local_name[ASHMEM_NAME_LEN - 1] = '\0';
		if (copy_to_user((void __user *)arg, local_name, sizeof(local_name)))
			return -EFAULT;
		return 0;
	}
	case ASHMEM_GET_SIZE:
		return i_size_read(file_inode(file));
	case ASHMEM_SET_PROT_MASK:
		seals = memfd_fcntl(file, F_GET_SEALS, 0);
		if (seals < 0)
			return seals;
		/* the memfd compat layer cannot unset these */
		prot = arg | PROT_READ | PROT_EXEC;
		is_writable = !(seals & ASHMEM_MEMFD_WRITE_SEALS);
		if (!is_writable && (prot & PROT_WRITE))
			return -EINVAL;	/* cannot add PROT bits */
		if (is_writable && !(prot & PROT_WRITE)) {
			ret = memfd_fcntl(file, F_ADD_SEALS, F_SEAL_FUTURE_WRITE);
			if (ret < 0)
				return ret;
		}
		return 0;
	case ASHMEM_GET_PROT_MASK:
		seals = memfd_fcntl(file, F_GET_SEALS, 0);
		if (seals < 0)
			return seals;
		prot = PROT_READ | PROT_EXEC;
		if (!(seals & ASHMEM_MEMFD_WRITE_SEALS))
			prot |= PROT_WRITE;
		return prot;
	case ASHMEM_GET_FILE_ID: {
		unsigned long ino = file_inode(file)->i_ino;

		if (copy_to_user((void __user *)arg, &ino, sizeof(ino)))
			return -EFAULT;
		return 0;
	}
	/* a memfd has no unpinning: pin is a no-op and nothing is ever purged */
	case ASHMEM_PIN:
		return ASHMEM_NOT_PURGED;
	case ASHMEM_UNPIN:
		return 0;
	case ASHMEM_GET_PIN_STATUS:
		return ASHMEM_IS_PINNED;
	case ASHMEM_PURGE_ALL_CACHES:
		return capable(CAP_SYS_ADMIN) ? 0 : -EPERM;
	/*
	 * SET_NAME / SET_SIZE are only reachable when a caller thinks it holds an ashmem fd but has a memfd; libcutils
	 * sets name and size at construction (it knows which kind it made), so this should never happen.
	 */
	case ASHMEM_SET_NAME:
	case ASHMEM_SET_SIZE:
		return -EINVAL;
	default:
		return -ENOTTY;
	}
}
