module gc

// Heap configuration
// Default heap size in bytes
const default_heap_size = u32(32 * 1024 * 1024) // 32MB

// Number of heap partitions for fragmentation reduction
const default_partitions = 8
// Minimum object size in bytes
const min_object_size = 16
// GC trigger threshold (percentage of heap used)
const gc_trigger_threshold = 0.75
// Maximum number of roots to scan
const max_roots = 10000

// Object header for tracking allocations
struct ObjectHeader {
mut:
	size    u32  // Size of the object in bytes
	marked  bool // Mark bit for GC
	type_id u32  // Type identifier for conservative scanning
	next    &ObjectHeader = unsafe { nil } // Next object in free list
}

// Heap partition to reduce fragmentation
struct HeapPartition {
mut:
	start_addr voidptr
	size       u32
	used       u32
	free_list  &ObjectHeader = unsafe { nil }
	objects    []&ObjectHeader
}

// Root set entry for GC scanning
struct GCRoot {
	addr voidptr
	size u32
}

// Main garbage collector structure
pub struct GarbageCollector {
mut:
	heap_base       voidptr
	heap_size       u32
	partitions      []HeapPartition
	num_partitions  u32
	total_allocated u32
	total_freed     u32
	gc_count        u32
	roots           []GCRoot
	stack_bottom    voidptr
	stack_top       voidptr
	enabled         bool = true
}

pub fn (gc_ &GarbageCollector) heap_size() u32 {
	return gc_.heap_size
}

pub fn (gc_ &GarbageCollector) num_partitions() u32 {
	return gc_.num_partitions
}

// Initialize the garbage collector
pub fn new_garbage_collector(heap_size u32) &GarbageCollector {
	mut gc_ := &GarbageCollector{
		heap_size:      if heap_size == 0 { default_heap_size } else { heap_size }
		num_partitions: default_partitions
	}

	// Allocate heap memory
	gc_.heap_base = unsafe { malloc(int(heap_size)) }
	if gc_.heap_base == unsafe { nil } {
		panic('Failed to allocate heap memory')
	}

	// Initialize partitions
	partition_size := gc_.heap_size / gc_.num_partitions
	gc_.partitions = []HeapPartition{len: int(gc_.num_partitions)}

	for i in 0 .. gc_.num_partitions {
		mut partition := &gc_.partitions[i]
		partition.start_addr = unsafe { voidptr(usize(gc_.heap_base) + usize(i * partition_size)) }
		partition.size = partition_size
		partition.used = 0
		partition.objects = []&ObjectHeader{}

		// Initialize free list with entire partition
		header := &ObjectHeader{
			size:   partition_size - sizeof(ObjectHeader)
			marked: false
			next:   unsafe { nil }
		}
		unsafe {
			*(&ObjectHeader(partition.start_addr)) = *header
		}
		partition.free_list = unsafe { &ObjectHeader(partition.start_addr) }
	}

	return gc_
}

// Allocate memory with conservative GC support
pub fn (mut gc_ GarbageCollector) alloc(size u32) voidptr {
	if !gc_.enabled {
		return unsafe { malloc(int(size)) }
	}

	// Align size to minimum object size
	aligned_size := ((size + min_object_size - 1) / min_object_size) * min_object_size
	total_size := aligned_size + sizeof(ObjectHeader)

	// Find best partition based on size
	mut partition_idx := gc_.find_best_partition(total_size)
	if partition_idx == -1 {
		// Try garbage collection first
		gc_.collect()
		partition_idx = gc_.find_best_partition(total_size)
		if partition_idx == -1 {
			return unsafe { nil } // Out of memory
		}
	}

	mut partition := &gc_.partitions[partition_idx]

	// Find free block in partition
	mut prev := unsafe { &ObjectHeader(nil) }
	mut current := partition.free_list

	for current != unsafe { nil } {
		if current.size >= total_size {
			// Split block if necessary
			if current.size > total_size + sizeof(ObjectHeader) + min_object_size {
				new_block := unsafe { &ObjectHeader(voidptr(usize(current) + usize(total_size))) }
				unsafe {
					*new_block = ObjectHeader{
						size:   current.size - total_size
						marked: false
						next:   current.next
					}
				}
				current.next = new_block
				current.size = total_size - sizeof(ObjectHeader)
			}

			// Remove from free list
			if prev == unsafe { nil } {
				partition.free_list = current.next
			} else {
				prev.next = current.next
			}

			// Initialize object header
			current.marked = false
			current.type_id = 0 // Conservative GC doesn't use type info
			current.next = unsafe { nil }

			// Add to objects list
			partition.objects << current
			partition.used += total_size
			gc_.total_allocated += total_size

			// Check if GC should be triggered
			if gc_.should_collect() {
				gc_.collect()
			}

			// Return pointer to object data (after header)
			return unsafe { voidptr(usize(current) + sizeof(ObjectHeader)) }
		}
		prev = current
		current = current.next
	}

	return unsafe { nil } // No suitable block found
}

// Find the best partition for allocation
fn (gc_ &GarbageCollector) find_best_partition(size u32) int {
	mut best_idx := -1
	mut best_fit := u32(0xffffffff)

	for i, partition in gc_.partitions {
		available := partition.size - partition.used
		if available >= size && available < best_fit {
			best_fit = available
			best_idx = i
		}
	}

	return best_idx
}

// Check if garbage collection should be triggered
fn (gc_ &GarbageCollector) should_collect() bool {
	if gc_.total_allocated == 0 {
		return false
	}

	usage_ratio := f64(gc_.total_allocated) / f64(gc_.heap_size)
	return usage_ratio >= gc_trigger_threshold
}

// Add a root to the root set
pub fn (mut gc_ GarbageCollector) add_root(addr voidptr, size u32) {
	if gc_.roots.len >= max_roots {
		return
	}

	root := GCRoot{
		addr: addr
		size: size
	}
	gc_.roots << root
}

// Remove a root from the root set
pub fn (mut gc_ GarbageCollector) remove_root(addr voidptr) {
	for i, root in gc_.roots {
		if root.addr == addr {
			gc_.roots.delete(i)
			break
		}
	}
}

// Mark and sweep garbage collection
pub fn (mut gc_ GarbageCollector) collect() {
	if !gc_.enabled {
		return
	}

	gc_.gc_count++

	// Mark phase
	gc_.mark_phase()

	// Sweep phase
	gc_.sweep_phase()
}

// Mark phase: mark all reachable objects
fn (mut gc_ GarbageCollector) mark_phase() {
	// Clear all marks first
	for mut partition in gc_.partitions {
		for mut obj in partition.objects {
			obj.marked = false
		}
	}

	// Mark from roots
	for root in gc_.roots {
		gc_.mark_from_root(root.addr, root.size)
	}

	// Mark from stack (conservative scanning)
	gc_.mark_from_stack()

	// Mark from registers (conservative scanning)
	gc_.mark_from_registers()
}

// Mark objects reachable from a root
fn (mut gc_ GarbageCollector) mark_from_root(addr voidptr, size u32) {
	if addr == unsafe { nil } || size == 0 {
		return
	}

	// Conservative scanning: treat every aligned pointer-sized value as potential pointer
	ptr_size := sizeof(voidptr)
	num_ptrs := size / u32(ptr_size)

	for i in 0 .. num_ptrs {
		potential_ptr := unsafe { *(&voidptr(usize(addr) + usize(i * ptr_size))) }
		gc_.mark_object(potential_ptr)
	}
}

// Mark objects reachable from stack
fn (mut gc_ GarbageCollector) mark_from_stack() {
	// Get current stack pointer (approximation)
	mut stack_var := 0
	current_sp := voidptr(&stack_var)

	// Determine stack direction and bounds
	mut stack_start := gc_.stack_bottom
	if stack_start == unsafe { nil } {
		stack_start = current_sp
	}
	mut stack_end := gc_.stack_top
	if stack_end == unsafe { nil } {
		stack_end = current_sp
	}

	// Ensure correct order
	if usize(stack_start) > usize(stack_end) {
		temp := stack_start
		stack_start = stack_end
		stack_end = temp
	}

	stack_size := usize(stack_end) - usize(stack_start)
	gc_.mark_from_root(stack_start, u32(stack_size))
}

// Mark objects reachable from registers (simplified)
fn (mut gc_ GarbageCollector) mark_from_registers() {
	// In a real implementation, we would save all registers and scan them
	// For simplicity, we'll just scan some local variables
	mut local_vars := unsafe { [10]voidptr{} }

	for i in 0 .. local_vars.len {
		local_vars[i] = unsafe { nil }
	}

	gc_.mark_from_root(voidptr(&local_vars[0]), sizeof(local_vars))
}

// Mark a specific object if it's in our heap
fn (mut gc_ GarbageCollector) mark_object(ptr voidptr) {
	if ptr == unsafe { nil } {
		return
	}

	// Check if pointer is in our heap
	if !gc_.is_heap_pointer(ptr) {
		return
	}

	// Find the object header
	mut obj_header := gc_.find_object_header(ptr)
	if obj_header != unsafe { nil } && !obj_header.marked {
		obj_header.marked = true

		// Recursively mark objects referenced by this object
		obj_data := unsafe { voidptr(usize(obj_header) + sizeof(ObjectHeader)) }
		gc_.mark_from_root(obj_data, obj_header.size)
	}
}

// Check if pointer is within our heap bounds
fn (gc_ &GarbageCollector) is_heap_pointer(ptr voidptr) bool {
	heap_start := usize(gc_.heap_base)
	heap_end := heap_start + usize(gc_.heap_size)
	ptr_addr := usize(ptr)

	return ptr_addr >= heap_start && ptr_addr < heap_end
}

// Find object header for a given pointer
fn (gc_ &GarbageCollector) find_object_header(ptr voidptr) &ObjectHeader {
	for partition in gc_.partitions {
		for obj in partition.objects {
			obj_data := unsafe { voidptr(usize(obj) + sizeof(ObjectHeader)) }
			obj_end := unsafe { voidptr(usize(obj_data) + usize(obj.size)) }

			if usize(ptr) >= usize(obj_data) && usize(ptr) < usize(obj_end) {
				return unsafe { obj }
			}
		}
	}
	return unsafe { nil }
}

// Sweep phase: free unmarked objects
fn (mut gc_ GarbageCollector) sweep_phase() {
	for mut partition in gc_.partitions {
		mut i := 0
		for i < partition.objects.len {
			obj := partition.objects[i]
			if !obj.marked {
				// Free this object
				gc_.free_object(mut partition, obj, i)
			} else {
				i++
			}
		}
	}
}

// Free an object and add it to the free list
fn (mut gc_ GarbageCollector) free_object(mut partition HeapPartition, obj &ObjectHeader, obj_idx int) {
	total_size := obj.size + sizeof(ObjectHeader)

	// Remove from objects list
	partition.objects.delete(obj_idx)
	partition.used -= total_size
	gc_.total_freed += total_size

	// Add to free list
	unsafe {
		obj.next = partition.free_list
		obj.marked = false
	}
	partition.free_list = unsafe { obj }

	// Try to coalesce adjacent free blocks
	gc_.coalesce_free_blocks(mut partition)
}

/// Coalesce adjacent free blocks to reduce fragmentation
fn (mut gc_ GarbageCollector) coalesce_free_blocks(mut partition HeapPartition) {
	if partition.free_list == unsafe { nil } {
		return
	}

	// Sort free list by address for easier coalescing
	mut free_blocks := []&ObjectHeader{}
	mut current := partition.free_list

	for current != unsafe { nil } {
		free_blocks << current
		current = current.next
	}

	if free_blocks.len == 0 {
		return
	}

	// Simple insertion sort by address
	for i in 1 .. free_blocks.len {
		mut j := i
		for j > 0 && usize(free_blocks[j]) < usize(free_blocks[j - 1]) {
			temp := free_blocks[j]
			free_blocks[j] = free_blocks[j - 1]
			free_blocks[j - 1] = temp
			j--
		}
	}

	// Coalesce adjacent blocks
	mut coalesced := []&ObjectHeader{}
	mut idx := 0

	for idx < free_blocks.len {
		mut current_block := free_blocks[idx]
		mut total_size := current_block.size + sizeof(ObjectHeader)

		// Check for adjacent blocks
		mut next_idx := idx + 1
		for next_idx < free_blocks.len {
			next_block := free_blocks[next_idx]
			expected_next := unsafe { voidptr(usize(current_block) + usize(total_size)) }

			if expected_next == voidptr(next_block) {
				// Adjacent blocks found, merge them
				total_size += next_block.size + sizeof(ObjectHeader)
				next_idx++
			} else {
				break
			}
		}

		// Update block size
		current_block.size = total_size - sizeof(ObjectHeader)
		coalesced << current_block

		// Move to next unprocessed block
		idx = next_idx
	}

	// Rebuild free list
	partition.free_list = if coalesced.len > 0 {
		coalesced[0]
	} else {
		unsafe { &ObjectHeader(nil) }
	}

	for k in 0 .. coalesced.len - 1 {
		coalesced[k].next = coalesced[k + 1]
	}

	if coalesced.len > 0 {
		coalesced[coalesced.len - 1].next = unsafe { nil }
	}
}

// Set stack bounds for conservative scanning
pub fn (mut gc_ GarbageCollector) set_stack_bounds(bottom voidptr, top voidptr) {
	gc_.stack_bottom = bottom
	gc_.stack_top = top
}

// Get GC statistics
pub struct GCStats {
pub:
	total_allocated u32
	total_freed     u32
	gc_count        u32
	heap_size       u32
	heap_used       u32
}

pub fn (gc_ &GarbageCollector) get_stats() GCStats {
	mut heap_used := u32(0)
	for partition in gc_.partitions {
		heap_used += partition.used
	}

	return GCStats{
		total_allocated: gc_.total_allocated
		total_freed:     gc_.total_freed
		gc_count:        gc_.gc_count
		heap_size:       gc_.heap_size
		heap_used:       heap_used
	}
}

// Enable or disable garbage collection
pub fn (mut gc_ GarbageCollector) set_enabled(enabled bool) {
	gc_.enabled = enabled
}

// Force immediate garbage collection
pub fn (mut gc_ GarbageCollector) force_collect() {
	gc_.collect()
}

// Cleanup garbage collector
pub fn (mut gc_ GarbageCollector) destroy() {
	if gc_.heap_base != unsafe { nil } {
		unsafe { free(gc_.heap_base) }
		gc_.heap_base = unsafe { nil }
	}
}
