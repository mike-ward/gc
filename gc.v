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

// Enhanced GC configuration
pub struct GCConfig {
pub:
	heap_size           u32  = default_heap_size
	num_partitions      u32  = default_partitions
	trigger_threshold   f64  = gc_trigger_threshold
	max_roots           int  = max_roots
	enable_coalescing   bool = true
	enable_compaction   bool
	debug_mode          bool
	allocation_tracking bool
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
	// Configuration
	config GCConfig
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
		heap_size:                   if heap_size == 0 { default_heap_size } else { heap_size }
		num_partitions:              default_partitions
		incremental_partition_index: 0
		config:                      GCConfig{}
	}

	// Allocate heap memory
	gc_.heap_base = unsafe { malloc(int(gc_.heap_size)) }
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

// Enhanced constructor with configuration
pub fn new_garbage_collector_with_config(config GCConfig) &GarbageCollector {
	mut gc_ := &GarbageCollector{
		heap_size:                   config.heap_size
		num_partitions:              config.num_partitions
		incremental_partition_index: 0
		config:                      config
	}

	gc_.heap_base = unsafe { malloc(int(config.heap_size)) }
	if gc_.heap_base == unsafe { nil } {
		panic('Failed to allocate heap memory')
	}

	// Initialize partitions with size-based allocation strategy
	gc_.init_partitions_optimized()

	return gc_
}

// Optimized partition initialization with size classes
fn (mut gc_ GarbageCollector) init_partitions_optimized() {
	partition_size := gc_.heap_size / gc_.num_partitions
	gc_.partitions = []HeapPartition{len: int(gc_.num_partitions)}

	for i in 0 .. gc_.num_partitions {
		mut partition := &gc_.partitions[i]
		partition.start_addr = unsafe { voidptr(usize(gc_.heap_base) + usize(i * partition_size)) }
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

// Optimized allocation with size class routing
pub fn (mut gc_ GarbageCollector) alloc_optimized(size u32) voidptr {
	if !gc_.enabled {
		return unsafe { malloc(int(size)) }
	}

	// Route small allocations to optimized path
	if size <= 512 {
		return gc_.alloc_small_object(size)
	}

	// Use regular allocation for larger objects
	return gc_.alloc(size)
}

// Fast path for small object allocation
fn (mut gc_ GarbageCollector) alloc_small_object(size u32) voidptr {
	// Find appropriate size class
	size_class := gc_.get_size_class(size)

	// Try to find a partition optimized for this size class
	partition_idx := int(size_class % gc_.num_partitions)

	aligned_size := ((size + min_object_size - 1) / min_object_size) * min_object_size
	total_size := aligned_size + sizeof(ObjectHeader)

	mut partition := &gc_.partitions[partition_idx]

	// Quick allocation attempt
	if partition.free_list != unsafe { nil } && partition.free_list.size >= total_size {
		return gc_.alloc_from_partition(mut partition, total_size)
	}

	// Fall back to regular allocation
	return gc_.alloc(size)
}

// Get size class for small object optimization
fn (gc_ &GarbageCollector) get_size_class(size u32) u32 {
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

// Allocate from specific partition (optimized path)
fn (mut gc_ GarbageCollector) alloc_from_partition(mut partition HeapPartition, total_size u32) voidptr {
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
		gc_.total_allocated += total_size

		return unsafe { voidptr(usize(current) + sizeof(ObjectHeader)) }
	}

	return unsafe { nil }
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
	if gc_.config.enable_coalescing {
		gc_.coalesce_free_blocks(mut partition)
	}
}

// Coalesce adjacent free blocks to reduce fragmentation
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

// Incremental collection (collect one partition at a time)
pub fn (mut gc_ GarbageCollector) collect_incremental() {
	if !gc_.enabled {
		return
	}

	// Round-robin incremental collection using instance field
	if gc_.incremental_partition_index >= int(gc_.num_partitions) {
		gc_.incremental_partition_index = 0
	}

	// Collect only one partition
	gc_.collect_partition(gc_.incremental_partition_index)
	gc_.incremental_partition_index++
}

// Collect a specific partition
fn (mut gc_ GarbageCollector) collect_partition(partition_idx int) {
	if partition_idx < 0 || partition_idx >= gc_.partitions.len {
		return
	}

	mut partition := &gc_.partitions[partition_idx]

	// Mark phase for this partition only
	for mut obj in partition.objects {
		obj.marked = false
	}

	// Mark from roots (only objects in this partition)
	for root in gc_.roots {
		gc_.mark_from_root_partition(root.addr, root.size, partition_idx)
	}

	// Sweep phase for this partition
	mut i := 0
	for i < partition.objects.len {
		obj := partition.objects[i]
		if !obj.marked {
			gc_.free_object(mut partition, obj, i)
		} else {
			i++
		}
	}
}

// Mark from root but only for specific partition
fn (mut gc_ GarbageCollector) mark_from_root_partition(addr voidptr, size u32, partition_idx int) {
	if addr == unsafe { nil } || size == 0 || partition_idx >= gc_.partitions.len {
		return
	}

	ptr_size := sizeof(voidptr)
	num_ptrs := size / u32(ptr_size)

	for i in 0 .. num_ptrs {
		potential_ptr := unsafe { *(&voidptr(usize(addr) + usize(i * ptr_size))) }
		gc_.mark_object_in_partition(potential_ptr, partition_idx)
	}
}

// Mark object if it's in specific partition
fn (mut gc_ GarbageCollector) mark_object_in_partition(ptr voidptr, partition_idx int) {
	if ptr == unsafe { nil } || partition_idx >= gc_.partitions.len {
		return
	}

	mut partition := gc_.partitions[partition_idx]
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
				gc_.mark_from_root_partition(obj_data, obj.size, partition_idx)
			}
			break
		}
	}
}

// Reset incremental collection state
pub fn (mut gc_ GarbageCollector) reset_incremental_collection() {
	gc_.incremental_partition_index = 0
}

// Get current incremental partition index
pub fn (gc_ &GarbageCollector) get_incremental_partition_index() int {
	return gc_.incremental_partition_index
}

// Memory compaction to reduce fragmentation
pub fn (mut gc_ GarbageCollector) compact() {
	if !gc_.enabled || !gc_.config.enable_compaction {
		return
	}

	for mut partition in gc_.partitions {
		gc_.compact_partition(mut partition)
	}
}

// Compact a single partition
fn (mut gc_ GarbageCollector) compact_partition(mut partition HeapPartition) {
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

pub fn (gc_ &GarbageCollector) get_detailed_stats() DetailedGCStats {
	mut partition_stats := []PartitionStats{}
	mut total_used := u32(0)
	mut total_free_blocks := 0

	for i, partition in gc_.partitions {
		free_blocks, largest_free := gc_.analyze_partition_fragmentation(partition)
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

	fragmentation_ratio := if gc_.heap_size > 0 {
		f64(total_free_blocks) / f64(gc_.heap_size) * 100.0
	} else {
		0.0
	}

	return DetailedGCStats{
		total_allocated:     gc_.total_allocated
		total_freed:         gc_.total_freed
		gc_count:            gc_.gc_count
		heap_size:           gc_.heap_size
		heap_used:           total_used
		fragmentation_ratio: fragmentation_ratio
		partition_stats:     partition_stats
		allocation_rate:     0.0 // Would need timing data
		collection_time_ms:  0.0 // Would need timing data
	}
}

// Analyze fragmentation in a partition
fn (gc_ &GarbageCollector) analyze_partition_fragmentation(partition HeapPartition) (int, u32) {
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
pub fn (mut gc_ GarbageCollector) alloc_tracked(size u32) voidptr {
	ptr := gc_.alloc(size)

	// Track allocation if debugging enabled
	// This would use allocation_map field when implemented

	return ptr
}

// Get allocation info for debugging
pub fn (gc_ &GarbageCollector) get_allocation_info(ptr voidptr) ?AllocationInfo {
	// This would look up in allocation_map
	// For now, return basic info by finding the object
	obj_header := gc_.find_object_header(ptr)
	if obj_header != unsafe { nil } {
		return AllocationInfo{
			size:      obj_header.size
			allocated: true
		}
	}
	return none
}

// Heap validation for debugging
pub fn (gc_ &GarbageCollector) validate_heap() bool {
	// Check heap integrity
	for i, partition in gc_.partitions {
		if !gc_.validate_partition(partition, i) {
			return false
		}
	}
	return true
}

// Validate a single partition
fn (gc_ &GarbageCollector) validate_partition(partition HeapPartition, partition_id int) bool {
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
pub fn (gc_ &GarbageCollector) print_heap_layout() {
	println('Heap Layout:')
	println('Base: ${gc_.heap_base}, Size: ${gc_.heap_size}')
	println('Partitions: ${gc_.num_partitions}')

	for i, partition in gc_.partitions {
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
