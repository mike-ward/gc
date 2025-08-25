module gc

fn test_gc_initialization() {
	mut collector := new_garbage_collector(1024 * 1024) // 1MB heap
	defer { collector.destroy() }

	assert collector.heap_size == 1024 * 1024
	assert collector.num_partitions == default_partitions
	assert collector.heap_base != unsafe { nil }
}

fn test_memory_allocation() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }

	// Allocate some memory
	ptr1 := collector.alloc(64)
	assert ptr1 != unsafe { nil }

	ptr2 := collector.alloc(128)
	assert ptr2 != unsafe { nil }

	ptr3 := collector.alloc(256)
	assert ptr3 != unsafe { nil }

	// Check statistics
	stats := collector.get_stats()
	assert stats.total_allocated > 0
}

fn test_garbage_collection() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }

	// Allocate memory without keeping references
	for i in 0 .. 100 {
		collector.alloc(1024)
	}

	initial_stats := collector.get_stats()

	// Force garbage collection
	collector.force_collect()

	final_stats := collector.get_stats()
	assert final_stats.gc_count > initial_stats.gc_count
}

fn test_root_management() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }

	mut test_var := 42

	// Add root
	collector.add_root(voidptr(&test_var), sizeof(test_var))
	assert collector.roots.len == 1

	// Remove root
	collector.remove_root(voidptr(&test_var))
	assert collector.roots.len == 0
}

fn test_enable_disable() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }

	assert collector.enabled == true

	collector.set_enabled(false)
	assert collector.enabled == false

	// When disabled, should use regular malloc
	ptr := collector.alloc(64)
	assert ptr != unsafe { nil }

	collector.set_enabled(true)
	assert collector.enabled == true
}
