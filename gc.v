module gc

// Heap configuration constants
const default_heap_size = u32(32 * 1024 * 1024) // 32MB
const default_max_heap_size = u32(512 * 1024 * 1024) // 512MB max
const default_partitions = 8
const min_object_size = 16
const gc_trigger_threshold = 0.75
const max_roots = 10000
const heap_growth_factor = 2.0 // Double the heap when growing
const min_growth_size = u32(4 * 1024 * 1024) // Minimum 4MB growth

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

// Enhanced GC configuration
pub struct GCConfig {
pub:
	heap_size           u32  = default_heap_size
	max_heap_size       u32  = default_max_heap_size
	num_partitions      u32  = default_partitions
	trigger_threshold   f64  = gc_trigger_threshold
	max_roots           int  = max_roots
	enable_coalescing   bool = true
	enable_compaction   bool
	debug_mode          bool
	allocation_tracking bool
	growth_factor       f64 = heap_growth_factor
	min_growth_size     u32 = min_growth_size
pub mut:
	enable_heap_growth bool = true
}

// Memory allocation statistics for debugging and profiling
pub struct AllocationInfo {
pub:
	size         u32
	partition_id int
	timestamp    u64
	allocated    bool
}

// Main garbage collector structure
pub struct GarbageCollector {
mut:
	heap_base       voidptr
	heap_size       u32
	max_heap_size   u32
	partitions      []HeapPartition
	num_partitions  u32
	total_allocated u32
	total_freed     u32
	gc_count        u32
	roots           []GCRoot
	stack_bottom    voidptr
	stack_top       voidptr
	enabled         bool = true
	// Incremental collection state
	incremental_partition_index int
	// Heap growth tracking
	growth_count         u32
	last_growth_gc_count u32
pub mut:
	// Configuration
	config GCConfig
}

pub fn (collector &GarbageCollector) heap_size() u32 {
	return collector.heap_size
}

pub fn (collector &GarbageCollector) num_partitions() u32 {
	return collector.num_partitions
}

// Initialize the garbage collector
pub fn new_garbage_collector(heap_size u32) &GarbageCollector {
	mut collector := &GarbageCollector{
		heap_size:                   if heap_size == 0 { default_heap_size } else { heap_size }
		max_heap_size:               default_max_heap_size
		num_partitions:              default_partitions
		incremental_partition_index: 0
		config:                      GCConfig{}
	}

	// Allocate heap memory
	collector.heap_base = unsafe { malloc(int(collector.heap_size)) }
	if collector.heap_base == unsafe { nil } {
		panic('Failed to allocate heap memory')
	}

	// Initialize partitions
	partition_size := collector.heap_size / collector.num_partitions
	collector.partitions = []HeapPartition{len: int(collector.num_partitions)}

	for i in 0 .. collector.num_partitions {
		mut partition := &collector.partitions[i]
		partition.start_addr = unsafe { voidptr(usize(collector.heap_base) + usize(i * partition_size)) }
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

	return collector
}

// Enhanced constructor with configuration
pub fn new_garbage_collector_with_config(config GCConfig) &GarbageCollector {
	mut collector := &GarbageCollector{
		heap_size:                   config.heap_size
		max_heap_size:               config.max_heap_size
		num_partitions:              config.num_partitions
		incremental_partition_index: 0
		config:                      config
	}

	collector.heap_base = unsafe { malloc(int(config.heap_size)) }
	if collector.heap_base == unsafe { nil } {
		panic('Failed to allocate heap memory')
	}

	// Initialize partitions with size-based allocation strategy
	collector.init_partitions_optimized()

	return collector
}

// Optimized partition initialization with size classes
fn (mut collector GarbageCollector) init_partitions_optimized() {
	partition_size := collector.heap_size / collector.num_partitions
	collector.partitions = []HeapPartition{len: int(collector.num_partitions)}

	for i in 0 .. collector.num_partitions {
		mut partition := &collector.partitions[i]
		partition.start_addr = unsafe { voidptr(usize(collector.heap_base) + usize(i * partition_size)) }
		partition.size = partition_size
		partition.used = 0
		partition.objects = []&ObjectHeader{cap: 100} // Pre-allocate capacity

		// Initialize free list
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
}

// Check if heap should grow
fn (collector &GarbageCollector) should_grow_heap() bool {
	if !collector.config.enable_heap_growth {
		return false
	}

	if collector.heap_size >= collector.max_heap_size {
		return false // Already at maximum size
	}

	// Don't grow too frequently - wait at least 5 GC cycles
	if collector.gc_count - collector.last_growth_gc_count < 5 {
		return false
	}

	// Calculate current usage
	usage_ratio := f64(collector.total_allocated) / f64(collector.heap_size)

	// Grow if we're using more than 90% after GC
	return usage_ratio > 0.9
}

// Calculate new heap size
fn (collector &GarbageCollector) calculate_new_heap_size() u32 {
	growth_factor := collector.config.growth_factor
	min_growth := collector.config.min_growth_size

	// Calculate size based on growth factor
	new_size_by_factor := u32(f64(collector.heap_size) * growth_factor)

	// Calculate size based on minimum growth
	new_size_by_min := collector.heap_size + min_growth

	// Use the larger of the two
	mut new_size := if new_size_by_factor > new_size_by_min {
		new_size_by_factor
	} else {
		new_size_by_min
	}

	// Cap at maximum heap size
	if new_size > collector.max_heap_size {
		new_size = collector.max_heap_size
	}

	return new_size
}

// Grow the heap
pub fn (mut collector GarbageCollector) grow_heap() bool {
	if !collector.should_grow_heap() {
		return false
	}

	new_heap_size := collector.calculate_new_heap_size()
	if new_heap_size <= collector.heap_size {
		return false // No growth possible
	}

	// Allocate new larger heap
	new_heap_base := unsafe { malloc(int(new_heap_size)) }
	if new_heap_base == unsafe { nil } {
		return false // Failed to allocate
	}

	// Copy existing data to new heap
	unsafe {
		C.memcpy(new_heap_base, collector.heap_base, int(collector.heap_size))
	}

	// Calculate size difference
	size_increase := new_heap_size - collector.heap_size

	// Free old heap
	unsafe { free(collector.heap_base) }

	// Update heap pointers
	old_heap_base := collector.heap_base
	collector.heap_base = new_heap_base
	heap_offset := usize(new_heap_base) - usize(old_heap_base)

	// Update all partition pointers
	for mut partition in collector.partitions {
		partition.start_addr = unsafe { voidptr(usize(partition.start_addr) + heap_offset) }

		// Update free list pointer
		if partition.free_list != unsafe { nil } {
			partition.free_list = unsafe { &ObjectHeader(usize(partition.free_list) + heap_offset) }
		}

		// Update object pointers
		for i in 0 .. partition.objects.len {
			partition.objects[i] = unsafe { &ObjectHeader(usize(partition.objects[i]) + heap_offset) }
		}

		// Update free list chain
		mut current := partition.free_list
		for current != unsafe { nil } {
			if current.next != unsafe { nil } {
				current.next = unsafe { &ObjectHeader(usize(current.next) + heap_offset) }
			}
			current = current.next
		}
	}

	// Add new space to the last partition
	mut last_partition := &collector.partitions[collector.partitions.len - 1]

	// Create new free block for the additional space
	new_space_start := unsafe {
		voidptr(usize(last_partition.start_addr) + usize(last_partition.size))
	}
	new_free_block := unsafe { &ObjectHeader(new_space_start) }

	unsafe {
		*new_free_block = ObjectHeader{
			size:   size_increase - sizeof(ObjectHeader)
			marked: false
			next:   last_partition.free_list
		}
	}
	last_partition.free_list = new_free_block
	last_partition.size += size_increase

	// Update collector state
	collector.heap_size = new_heap_size
	collector.growth_count++
	collector.last_growth_gc_count = collector.gc_count

	if collector.config.debug_mode {
		println('Heap grown from ${collector.heap_size - size_increase} to ${collector.heap_size} bytes (growth #${collector.growth_count})')
	}

	return true
}

// Update the allocation function to be more aggressive about growth
pub fn (mut collector GarbageCollector) alloc(size u32) voidptr {
	if !collector.enabled {
		return unsafe { malloc(int(size)) }
	}

	// Align size to minimum object size
	aligned_size := ((size + min_object_size - 1) / min_object_size) * min_object_size
	total_size := aligned_size + sizeof(ObjectHeader)

	// Find best partition based on size
	mut partition_idx := collector.find_best_partition(total_size)
	if partition_idx == -1 {
		// Try garbage collection first
		collector.collect()
		partition_idx = collector.find_best_partition(total_size)

		if partition_idx == -1 {
			// Try growing the heap - be more aggressive
			if collector.should_grow_after_failure(total_size) && collector.grow_heap() {
				partition_idx = collector.find_best_partition(total_size)
			}

			if partition_idx == -1 {
				return unsafe { nil } // Out of memory even after growth
			}
		}
	}

	mut partition := &collector.partitions[partition_idx]

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
			current.type_id = 0
			current.next = unsafe { nil }

			// Add to objects list
			partition.objects << current
			partition.used += total_size
			collector.total_allocated += total_size

			// Check if GC should be triggered
			if collector.should_collect() {
				collector.collect()
			}

			// Return pointer to object data (after header)
			return unsafe { voidptr(usize(current) + sizeof(ObjectHeader)) }
		}
		prev = current
		current = current.next
	}

	return unsafe { nil }
}

// Optimized allocation with size class routing
pub fn (mut collector GarbageCollector) alloc_optimized(size u32) voidptr {
	if !collector.enabled {
		return unsafe { malloc(int(size)) }
	}

	// Route small allocations to optimized path
	if size <= 512 {
		return collector.alloc_small_object(size)
	}

	// Use regular allocation for larger objects
	return collector.alloc(size)
}

// Fast path for small object allocation
fn (mut collector GarbageCollector) alloc_small_object(size u32) voidptr {
	// Find appropriate size class
	size_class := collector.get_size_class(size)

	// Try to find a partition optimized for this size class
	partition_idx := int(size_class % collector.num_partitions)

	aligned_size := ((size + min_object_size - 1) / min_object_size) * min_object_size
	total_size := aligned_size + sizeof(ObjectHeader)

	mut partition := &collector.partitions[partition_idx]

	// Quick allocation attempt
	if partition.free_list != unsafe { nil } && partition.free_list.size >= total_size {
		return collector.alloc_from_partition(mut partition, total_size)
	}

	// Fall back to regular allocation
	return collector.alloc(size)
}

// Get size class for small object optimization
fn (collector &GarbageCollector) get_size_class(size u32) u32 {
	if size <= 32 {
		return 0
	}
	if size <= 64 {
		return 1
	}
	if size <= 128 {
		return 2
	}
	if size <= 256 {
		return 3
	}
	if size <= 512 {
		return 4
	}
	return 5 // larger objects
}

// Check if we should attempt growth after allocation failure
fn (collector &GarbageCollector) should_grow_after_failure(requested_size u32) bool {
	if !collector.config.enable_heap_growth {
		return false
	}

	if collector.heap_size >= collector.max_heap_size {
		return false
	}

	// Always try to grow if we can't allocate and haven't reached max size
	// Check if the requested size would fit after growth
	new_size := collector.calculate_new_heap_size()
	additional_space := new_size - collector.heap_size

	return additional_space >= requested_size * 2 // Ensure some headroom
}

// Allocate from specific partition (optimized path)
fn (mut collector GarbageCollector) alloc_from_partition(mut partition HeapPartition, total_size u32) voidptr {
	mut current := partition.free_list

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
		partition.free_list = current.next

		// Initialize object header
		current.marked = false
		current.type_id = 0
		current.next = unsafe { nil }

		// Add to objects list
		partition.objects << current
		partition.used += total_size
		collector.total_allocated += total_size

		return unsafe { voidptr(usize(current) + sizeof(ObjectHeader)) }
	}

	return unsafe { nil }
}

// Find the best partition for allocation
fn (collector &GarbageCollector) find_best_partition(size u32) int {
	mut best_idx := -1
	mut best_fit := u32(0xffffffff)

	for i, partition in collector.partitions {
		available := partition.size - partition.used
		if available >= size && available < best_fit {
			best_fit = available
			best_idx = i
		}
	}

	return best_idx
}

// Check if garbage collection should be triggered
fn (collector &GarbageCollector) should_collect() bool {
	if collector.total_allocated == 0 {
		return false
	}

	usage_ratio := f64(collector.total_allocated) / f64(collector.heap_size)
	return usage_ratio >= gc_trigger_threshold
}

// Add a root to the root set
pub fn (mut collector GarbageCollector) add_root(addr voidptr, size u32) {
	if collector.roots.len >= max_roots {
		return
	}

	root := GCRoot{
		addr: addr
		size: size
	}
	collector.roots << root
}

// Remove a root from the root set
pub fn (mut collector GarbageCollector) remove_root(addr voidptr) {
	for i, root in collector.roots {
		if root.addr == addr {
			collector.roots.delete(i)
			break
		}
	}
}

// Mark and sweep garbage collection
pub fn (mut collector GarbageCollector) collect() {
	if !collector.enabled {
		return
	}

	collector.gc_count++

	// Mark phase
	collector.mark_phase()

	// Sweep phase
	collector.sweep_phase()
}

// Mark phase: mark all reachable objects
fn (mut collector GarbageCollector) mark_phase() {
	// Clear all marks first
	for mut partition in collector.partitions {
		for mut obj in partition.objects {
			obj.marked = false
		}
	}

	// Mark from roots
	for root in collector.roots {
		collector.mark_from_root(root.addr, root.size)
	}

	// Mark from stack (conservative scanning)
	collector.mark_from_stack()

	// Mark from registers (conservative scanning)
	collector.mark_from_registers()
}

// Mark objects reachable from a root
fn (mut collector GarbageCollector) mark_from_root(addr voidptr, size u32) {
	if addr == unsafe { nil } || size == 0 {
		return
	}

	// Conservative scanning: treat every aligned pointer-sized value as potential pointer
	ptr_size := sizeof(voidptr)
	num_ptrs := size / u32(ptr_size)

	for i in 0 .. num_ptrs {
		potential_ptr := unsafe { *(&voidptr(usize(addr) + usize(i * ptr_size))) }
		collector.mark_object(potential_ptr)
	}
}

// Mark objects reachable from stack
fn (mut collector GarbageCollector) mark_from_stack() {
	// Get current stack pointer (approximation)
	mut stack_var := 0
	current_sp := voidptr(&stack_var)

	// Determine stack direction and bounds
	mut stack_start := collector.stack_bottom
	if stack_start == unsafe { nil } {
		stack_start = current_sp
	}
	mut stack_end := collector.stack_top
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
	collector.mark_from_root(stack_start, u32(stack_size))
}

// Mark objects reachable from registers (simplified)
fn (mut collector GarbageCollector) mark_from_registers() {
	// In a real implementation, we would save all registers and scan them
	// For simplicity, we'll just scan some local variables
	mut local_vars := unsafe { [10]voidptr{} }

	for i in 0 .. local_vars.len {
		local_vars[i] = unsafe { nil }
	}

	collector.mark_from_root(voidptr(&local_vars[0]), sizeof(local_vars))
}

// Mark a specific object if it's in our heap
fn (mut collector GarbageCollector) mark_object(ptr voidptr) {
	if ptr == unsafe { nil } {
		return
	}

	// Check if pointer is in our heap
	if !collector.is_heap_pointer(ptr) {
		return
	}

	// Find the object header
	mut obj_header := collector.find_object_header(ptr)
	if obj_header != unsafe { nil } && !obj_header.marked {
		obj_header.marked = true

		// Recursively mark objects referenced by this object
		obj_data := unsafe { voidptr(usize(obj_header) + sizeof(ObjectHeader)) }
		collector.mark_from_root(obj_data, obj_header.size)
	}
}

// Check if pointer is within our heap bounds
fn (collector &GarbageCollector) is_heap_pointer(ptr voidptr) bool {
	heap_start := usize(collector.heap_base)
	heap_end := heap_start + usize(collector.heap_size)
	ptr_addr := usize(ptr)

	return ptr_addr >= heap_start && ptr_addr < heap_end
}

// Find object header for a given pointer
fn (collector &GarbageCollector) find_object_header(ptr voidptr) &ObjectHeader {
	for partition in collector.partitions {
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
fn (mut collector GarbageCollector) sweep_phase() {
	for mut partition in collector.partitions {
		mut i := 0
		for i < partition.objects.len {
			obj := partition.objects[i]
			if !obj.marked {
				// Free this object
				collector.free_object(mut partition, obj, i)
			} else {
				i++
			}
		}
	}
}

// Free an object and add it to the free list
fn (mut collector GarbageCollector) free_object(mut partition HeapPartition, obj &ObjectHeader, obj_idx int) {
	total_size := obj.size + sizeof(ObjectHeader)

	// Remove from objects list
	partition.objects.delete(obj_idx)
	partition.used -= total_size
	collector.total_freed += total_size

	// Add to free list
	unsafe {
		obj.next = partition.free_list
		obj.marked = false
	}
	partition.free_list = unsafe { obj }

	// Try to coalesce adjacent free blocks
	if collector.config.enable_coalescing {
		collector.coalesce_free_blocks(mut partition)
	}
}

// Coalesce adjacent free blocks to reduce fragmentation
fn (mut collector GarbageCollector) coalesce_free_blocks(mut partition HeapPartition) {
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

// Incremental collection (collect one partition at a time)
pub fn (mut collector GarbageCollector) collect_incremental() {
	if !collector.enabled {
		return
	}

	// Round-robin incremental collection using instance field
	if collector.incremental_partition_index >= int(collector.num_partitions) {
		collector.incremental_partition_index = 0
	}

	// Collect only one partition
	collector.collect_partition(collector.incremental_partition_index)
	collector.incremental_partition_index++
}

// Collect a specific partition
fn (mut collector GarbageCollector) collect_partition(partition_idx int) {
	if partition_idx < 0 || partition_idx >= collector.partitions.len {
		return
	}

	mut partition := &collector.partitions[partition_idx]

	// Mark phase for this partition only
	for mut obj in partition.objects {
		obj.marked = false
	}

	// Mark from roots (only objects in this partition)
	for root in collector.roots {
		collector.mark_from_root_partition(root.addr, root.size, partition_idx)
	}

	// Sweep phase for this partition
	mut i := 0
	for i < partition.objects.len {
		obj := partition.objects[i]
		if !obj.marked {
			collector.free_object(mut partition, obj, i)
		} else {
			i++
		}
	}
}

// Mark from root but only for specific partition
fn (mut collector GarbageCollector) mark_from_root_partition(addr voidptr, size u32, partition_idx int) {
	if addr == unsafe { nil } || size == 0 || partition_idx >= collector.partitions.len {
		return
	}

	ptr_size := sizeof(voidptr)
	num_ptrs := size / u32(ptr_size)

	for i in 0 .. num_ptrs {
		potential_ptr := unsafe { *(&voidptr(usize(addr) + usize(i * ptr_size))) }
		collector.mark_object_in_partition(potential_ptr, partition_idx)
	}
}

// Mark object if it's in specific partition
fn (mut collector GarbageCollector) mark_object_in_partition(ptr voidptr, partition_idx int) {
	if ptr == unsafe { nil } || partition_idx >= collector.partitions.len {
		return
	}

	mut partition := collector.partitions[partition_idx]
	partition_start := usize(partition.start_addr)
	partition_end := partition_start + usize(partition.size)
	ptr_addr := usize(ptr)

	// Check if pointer is in this partition
	if ptr_addr < partition_start || ptr_addr >= partition_end {
		return
	}

	// Find and mark object
	for mut obj in partition.objects {
		obj_data := unsafe { voidptr(usize(obj) + sizeof(ObjectHeader)) }
		obj_end := unsafe { voidptr(usize(obj_data) + usize(obj.size)) }

		if usize(ptr) >= usize(obj_data) && usize(ptr) < usize(obj_end) {
			if !obj.marked {
				obj.marked = true
				// Recursively mark referenced objects in this partition
				collector.mark_from_root_partition(obj_data, obj.size, partition_idx)
			}
			break
		}
	}
}

// Reset incremental collection state
pub fn (mut collector GarbageCollector) reset_incremental_collection() {
	collector.incremental_partition_index = 0
}

// Get current incremental partition index
pub fn (collector &GarbageCollector) get_incremental_partition_index() int {
	return collector.incremental_partition_index
}

// Memory compaction to reduce fragmentation
pub fn (mut collector GarbageCollector) compact() {
	if !collector.enabled || !collector.config.enable_compaction {
		return
	}

	for mut partition in collector.partitions {
		collector.compact_partition(mut partition)
	}
}

// Compact a single partition
fn (mut collector GarbageCollector) compact_partition(mut partition HeapPartition) {
	if partition.objects.len == 0 {
		return
	}

	// Sort objects by address
	mut live_objects := []&ObjectHeader{}
	for obj in partition.objects {
		if obj.marked {
			live_objects << obj
		}
	}

	// Simple compaction: move all live objects to start of partition
	mut current_addr := partition.start_addr

	for obj in live_objects {
		obj_size := obj.size + sizeof(ObjectHeader)
		if voidptr(obj) != current_addr {
			// Move object data
			unsafe {
				C.memmove(current_addr, obj, int(obj_size))
			}
		}
		current_addr = unsafe { voidptr(usize(current_addr) + usize(obj_size)) }
	}

	// Update free list
	remaining_size := partition.size - (usize(current_addr) - usize(partition.start_addr))
	if remaining_size > sizeof(ObjectHeader) {
		free_header := unsafe { &ObjectHeader(current_addr) }
		unsafe {
			*free_header = ObjectHeader{
				size:   u32(remaining_size) - sizeof(ObjectHeader)
				marked: false
				next:   nil
			}
		}
		partition.free_list = free_header
	} else {
		partition.free_list = unsafe { nil }
	}
}

// Set stack bounds for conservative scanning
pub fn (mut collector GarbageCollector) set_stack_bounds(bottom voidptr, top voidptr) {
	collector.stack_bottom = bottom
	collector.stack_top = top
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

pub fn (collector &GarbageCollector) get_stats() GCStats {
	mut heap_used := u32(0)
	for partition in collector.partitions {
		heap_used += partition.used
	}

	return GCStats{
		total_allocated: collector.total_allocated
		total_freed:     collector.total_freed
		gc_count:        collector.gc_count
		heap_size:       collector.heap_size
		heap_used:       heap_used
	}
}

// Get detailed memory statistics
pub struct DetailedGCStats {
pub:
	total_allocated     u32
	total_freed         u32
	gc_count            u32
	heap_size           u32
	heap_used           u32
	fragmentation_ratio f64
	partition_stats     []PartitionStats
	allocation_rate     f64
	collection_time_ms  f64
}

pub struct PartitionStats {
pub:
	id            int
	size          u32
	used          u32
	free_blocks   int
	largest_free  u32
	fragmentation f64
}

pub fn (collector &GarbageCollector) get_detailed_stats() DetailedGCStats {
	mut partition_stats := []PartitionStats{}
	mut total_used := u32(0)
	mut total_free_blocks := 0

	for i, partition in collector.partitions {
		free_blocks, largest_free := collector.analyze_partition_fragmentation(partition)
		fragmentation := if partition.size > 0 {
			f64(free_blocks) / f64(partition.size) * 100.0
		} else {
			0.0
		}

		partition_stats << PartitionStats{
			id:            i
			size:          partition.size
			used:          partition.used
			free_blocks:   free_blocks
			largest_free:  largest_free
			fragmentation: fragmentation
		}

		total_used += partition.used
		total_free_blocks += free_blocks
	}

	fragmentation_ratio := if collector.heap_size > 0 {
		f64(total_free_blocks) / f64(collector.heap_size) * 100.0
	} else {
		0.0
	}

	return DetailedGCStats{
		total_allocated:     collector.total_allocated
		total_freed:         collector.total_freed
		gc_count:            collector.gc_count
		heap_size:           collector.heap_size
		heap_used:           total_used
		fragmentation_ratio: fragmentation_ratio
		partition_stats:     partition_stats
		allocation_rate:     0.0 // Would need timing data
		collection_time_ms:  0.0 // Would need timing data
	}
}

// Analyze fragmentation in a partition
fn (collector &GarbageCollector) analyze_partition_fragmentation(partition HeapPartition) (int, u32) {
	mut free_blocks := 0
	mut largest_free := u32(0)
	mut current := partition.free_list

	for current != unsafe { nil } {
		free_blocks++
		if current.size > largest_free {
			largest_free = current.size
		}
		current = current.next
	}

	return free_blocks, largest_free
}

// Memory allocation with tracking (for debugging)
pub fn (mut collector GarbageCollector) alloc_tracked(size u32) voidptr {
	ptr := collector.alloc(size)

	// Track allocation if debugging enabled
	// This would use allocation_map field when implemented

	return ptr
}

// Get allocation info for debugging
pub fn (collector &GarbageCollector) get_allocation_info(ptr voidptr) ?AllocationInfo {
	// This would look up in allocation_map
	// For now, return basic info by finding the object
	obj_header := collector.find_object_header(ptr)
	if obj_header != unsafe { nil } {
		return AllocationInfo{
			size:      obj_header.size
			allocated: true
		}
	}
	return none
}

// Heap validation for debugging
pub fn (collector &GarbageCollector) validate_heap() bool {
	// Check heap integrity
	for i, partition in collector.partitions {
		if !collector.validate_partition(partition, i) {
			return false
		}
	}
	return true
}

// Validate a single partition
fn (collector &GarbageCollector) validate_partition(partition HeapPartition, partition_id int) bool {
	// Check if partition bounds are valid
	if partition.start_addr == unsafe { nil } || partition.size == 0 {
		return false
	}

	// Validate free list
	mut current := partition.free_list
	for current != unsafe { nil } {
		// Check if free block is within partition bounds
		block_start := usize(current)
		block_end := block_start + usize(current.size + sizeof(ObjectHeader))
		partition_start := usize(partition.start_addr)
		partition_end := partition_start + usize(partition.size)

		if block_start < partition_start || block_end > partition_end {
			return false
		}

		current = current.next
	}

	return true
}

// Print heap layout for debugging
pub fn (collector &GarbageCollector) print_heap_layout() {
	println('Heap Layout:')
	println('Base: ${collector.heap_base}, Size: ${collector.heap_size}')
	println('Max Size: ${collector.max_heap_size}, Growth Count: ${collector.growth_count}')
	println('Partitions: ${collector.num_partitions}')

	for i, partition in collector.partitions {
		println('Partition ${i}:')
		println('  Start: ${partition.start_addr}, Size: ${partition.size}')
		println('  Used: ${partition.used}, Objects: ${partition.objects.len}')

		// Count free blocks
		mut free_blocks := 0
		mut current := partition.free_list
		for current != unsafe { nil } {
			free_blocks++
			current = current.next
		}
		println('  Free blocks: ${free_blocks}')
	}
}

// Get heap growth statistics
pub struct HeapGrowthStats {
pub:
	current_size   u32
	max_size       u32
	growth_count   u32
	can_grow       bool
	growth_factor  f64
	last_growth_gc u32
}

pub fn (collector &GarbageCollector) get_growth_stats() HeapGrowthStats {
	return HeapGrowthStats{
		current_size:   collector.heap_size
		max_size:       collector.max_heap_size
		growth_count:   collector.growth_count
		can_grow:       collector.config.enable_heap_growth && collector.heap_size < collector.max_heap_size
		growth_factor:  collector.config.growth_factor
		last_growth_gc: collector.last_growth_gc_count
	}
}

// Force heap growth (for testing/manual control)
pub fn (mut collector GarbageCollector) force_grow_heap() bool {
	if collector.heap_size >= collector.max_heap_size {
		return false
	}

	// Temporarily override the growth check
	old_enable := collector.config.enable_heap_growth
	collector.config.enable_heap_growth = true

	result := collector.grow_heap()
	collector.config.enable_heap_growth = old_enable
	return result
}

// Enable or disable garbage collection
pub fn (mut collector GarbageCollector) set_enabled(enabled bool) {
	collector.enabled = enabled
}

// Force immediate garbage collection
pub fn (mut collector GarbageCollector) force_collect() {
	collector.collect()
}

// Cleanup garbage collector
pub fn (mut collector GarbageCollector) destroy() {
	if collector.heap_base != unsafe { nil } {
		unsafe { free(collector.heap_base) }
		collector.heap_base = unsafe { nil }
	}
}
