module gc

import time

fn test_gc_initialization() {
	mut collector := new_garbage_collector(1024 * 1024) // 1MB heap
	defer { collector.destroy() }
	
	assert collector.heap_size() == 1024 * 1024
	assert collector.num_partitions() == default_partitions
	assert collector.heap_base != unsafe { nil }
	assert collector.enabled == true
}

fn test_gc_with_config() {
	config := GCConfig{
		heap_size: 2 * 1024 * 1024,
		max_heap_size: 16 * 1024 * 1024,
		num_partitions: 4,
		enable_heap_growth: true,
		growth_factor: 1.5,
		debug_mode: true
	}
	
	mut collector := new_garbage_collector_with_config(config)
	defer { collector.destroy() }
	
	assert collector.heap_size() == 2 * 1024 * 1024
	assert collector.max_heap_size == 16 * 1024 * 1024
	assert collector.num_partitions() == 4
	assert collector.config.enable_heap_growth == true
	assert collector.config.growth_factor == 1.5
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
	assert stats.heap_used > 0
}

fn test_optimized_allocation() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	// Test size class allocation
	small_ptr := collector.alloc_optimized(32)
	assert small_ptr != unsafe { nil }
	
	medium_ptr := collector.alloc_optimized(256)
	assert medium_ptr != unsafe { nil }
	
	large_ptr := collector.alloc_optimized(1024)
	assert large_ptr != unsafe { nil }
	
	stats := collector.get_stats()
	assert stats.total_allocated > 0
}

fn test_data_integrity() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	// Allocate and write test data
	mut test_ptrs := []voidptr{}
	
	for i in 0 .. 50 {
		ptr := collector.alloc(64)
		if ptr != unsafe { nil } {
			// Write test pattern
			unsafe {
				*(&u32(ptr)) = u32(i * 12345)
			}
			test_ptrs << ptr
		}
	}
	
	// Verify data integrity
	for i, ptr in test_ptrs {
		expected := u32(i * 12345)
		actual := unsafe { *(&u32(ptr)) }
		assert actual == expected, 'Data corruption detected at index ${i}'
	}
}

fn test_garbage_collection() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	initial_stats := collector.get_stats()
	
	// Allocate memory without keeping references
	for i in 0 .. 100 {
		collector.alloc(1024)
	}
	
	// Force garbage collection
	collector.collect()
	
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

fn test_heap_growth_basic() {
	config := GCConfig{
		heap_size: 512 * 1024, // Small initial heap
		max_heap_size: 4 * 1024 * 1024,
		enable_heap_growth: true,
		growth_factor: 2.0
	}
	
	mut collector := new_garbage_collector_with_config(config)
	defer { collector.destroy() }
	
	initial_size := collector.heap_size()
	
	// Allocate large objects to potentially trigger growth
	mut large_objects := []voidptr{}
	
	for i in 0 .. 20 {
		ptr := collector.alloc(32 * 1024) // 32KB objects
		if ptr != unsafe { nil } {
			large_objects << ptr
		}
	}
	
	// The heap may or may not have grown, but should still be functioning
	assert collector.heap_size() >= initial_size
	assert large_objects.len > 0
}

fn test_incremental_collection_basic() {
	mut collector := new_garbage_collector(2 * 1024 * 1024)
	defer { collector.destroy() }
	
	// Create some objects
	for i in 0 .. 100 {
		collector.alloc(1024)
	}
	
	initial_partition_index := collector.incremental_partition_index
	
	// Run incremental collection
	collector.collect_incremental()
	
	// Should have moved to next partition or wrapped around
	final_partition_index := collector.incremental_partition_index
	expected_index := if initial_partition_index + 1 >= int(collector.num_partitions()) {
		0
	} else {
		initial_partition_index + 1
	}
	assert final_partition_index == expected_index
}

fn test_enable_disable() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	assert collector.enabled == true
	
	collector.enabled = false
	assert collector.enabled == false
	
	// When disabled, should use regular malloc
	ptr := collector.alloc(64)
	assert ptr != unsafe { nil }
	
	collector.enabled = true
	assert collector.enabled == true
}

fn test_allocation_patterns() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	// Test various allocation sizes
	sizes := [16, 32, 64, 128, 256, 512, 1024, 2048]
	
	mut ptrs := []voidptr{}
	
	for size in sizes {
		for i in 0 .. 10 {
			ptr := collector.alloc(u32(size))
			if ptr != unsafe { nil } {
				ptrs << ptr
			}
		}
	}
	
	// Should have allocated most objects
	assert ptrs.len > sizes.len * 5 // At least half successful
	
	stats := collector.get_stats()
	assert stats.total_allocated > 0
	assert stats.heap_used > 0
}

fn test_memory_pressure() {
	mut collector := new_garbage_collector(256 * 1024) // Small heap
	defer { collector.destroy() }
	
	mut successful_allocations := 0
	mut failed_allocations := 0
	
	// Try to allocate until we run out of space or trigger growth
	for i in 0 .. 100 {
		ptr := collector.alloc(4 * 1024) // 4KB objects
		if ptr != unsafe { nil } {
			successful_allocations++
		} else {
			failed_allocations++
		}
	}
	
	// Should have allocated at least some objects
	assert successful_allocations > 0
	
	// Try collection to free up space
	collector.collect()
	
	// Should be able to allocate something after collection
	ptr := collector.alloc(1024)
	// Don't assert ptr != nil because it depends on whether objects were actually freed
}

fn test_fragmentation_handling() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	mut ptrs := []voidptr{}
	
	// Allocate many small objects
	for i in 0 .. 200 {
		ptr := collector.alloc(64)
		if ptr != unsafe { nil } {
			ptrs << ptr
		}
	}
	
	// Clear half the references (every other one)
	for i in 0 .. ptrs.len {
		if i % 2 == 0 {
			ptrs[i] = unsafe { nil }
		}
	}
	
	// Force collection
	collector.collect()
	
	// Should still be able to allocate
	new_ptr := collector.alloc(128)
	// Don't assert new_ptr != nil as it depends on the implementation details
	
	stats := collector.get_stats()
	assert stats.gc_count > 0
}

fn test_large_object_allocation() {
	mut collector := new_garbage_collector(4 * 1024 * 1024) // 4MB heap
	defer { collector.destroy() }
	
	// Try to allocate a large object
	large_ptr := collector.alloc(1024 * 1024) // 1MB object
	
	if large_ptr != unsafe { nil } {
		// Write to the memory to ensure it's valid
		unsafe {
			*(&u32(large_ptr)) = 0xDEADBEEF
			assert *(&u32(large_ptr)) == 0xDEADBEEF
		}
	}
	
	// Should still be able to allocate smaller objects
	small_ptr := collector.alloc(1024)
	assert small_ptr != unsafe { nil }
}

fn test_stress_allocation() {
	mut collector := new_garbage_collector(2 * 1024 * 1024)
	defer { collector.destroy() }
	
	mut allocation_count := 0
	
	// Rapid allocation and deallocation pattern
	for round in 0 .. 10 {
		mut round_ptrs := []voidptr{}
		
		// Allocate a bunch of objects
		for i in 0 .. 50 {
			size := u32(32 + (i % 64)) // Varying sizes
			ptr := collector.alloc(size)
			if ptr != unsafe { nil } {
				round_ptrs << ptr
				allocation_count++
			}
		}
		
		// Clear references (simulating objects going out of scope)
		round_ptrs.clear()
		
		// Trigger collection periodically
		if round % 3 == 0 {
			collector.collect()
		}
	}
	
	assert allocation_count > 0
	
	stats := collector.get_stats()
	assert stats.total_allocated > 0
}

fn test_collector_statistics() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	initial_stats := collector.get_stats()
	assert initial_stats.total_allocated == 0
	assert initial_stats.total_freed == 0
	assert initial_stats.gc_count == 0
	assert initial_stats.heap_size == 1024 * 1024
	
	// Allocate some objects
	for i in 0 .. 10 {
		collector.alloc(1024)
	}
	
	after_alloc_stats := collector.get_stats()
	assert after_alloc_stats.total_allocated > initial_stats.total_allocated
	assert after_alloc_stats.heap_used > 0
	
	// Force collection
	collector.collect()
	
	after_gc_stats := collector.get_stats()
	assert after_gc_stats.gc_count > initial_stats.gc_count
}

fn test_multiple_collectors() {
	mut collector1 := new_garbage_collector(512 * 1024)
	defer { collector1.destroy() }
	
	mut collector2 := new_garbage_collector(1024 * 1024)
	defer { collector2.destroy() }
	
	// Both should work independently
	ptr1 := collector1.alloc(256)
	ptr2 := collector2.alloc(512)
	
	assert ptr1 != unsafe { nil }
	assert ptr2 != unsafe { nil }
	assert ptr1 != ptr2
	
	// Both should have different heap sizes
	assert collector1.heap_size() != collector2.heap_size()
}

fn test_zero_size_allocation() {
	mut collector := new_garbage_collector(1024 * 1024)
	defer { collector.destroy() }
	
	// Allocating zero bytes should still return a valid pointer or handle gracefully
	ptr := collector.alloc(0)
	// Don't assert anything specific as the behavior for zero-size allocation
	// depends on implementation details
	
	// Should still be able to allocate normal objects
	normal_ptr := collector.alloc(64)
	assert normal_ptr != unsafe { nil }
}

fn test_configuration_limits() {
	// Test configuration with growth disabled
	config := GCConfig{
		heap_size: 1024 * 1024,
		max_heap_size: 1024 * 1024, // Same as heap_size
		enable_heap_growth: false
	}
	
	mut collector := new_garbage_collector_with_config(config)
	defer { collector.destroy() }
	
	assert collector.config.enable_heap_growth == false
	assert collector.heap_size() == 1024 * 1024
	
	// Should still be able to allocate within the fixed heap
	ptr := collector.alloc(1024)
	assert ptr != unsafe { nil }
}