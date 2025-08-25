import gc
import time

// Test structures for allocation
struct Node {
mut:
	value int
	data  []u8
	next  &Node = unsafe { nil }
}

struct LargeObject {
mut:
	id        int
	data      [1000]u8
	timestamp u64
}

struct SmallObject {
mut:
	id    int
	value f64
}

fn main() {
	println('=== V Language Growable Garbage Collector Demo ===\n')

	// Configure a growable heap collector
	config := gc.GCConfig{
		heap_size:          4 * 1024 * 1024  // Start with 4MB
		max_heap_size:      64 * 1024 * 1024 // Can grow to 64MB
		num_partitions:     8
		enable_heap_growth: true
		growth_factor:      1.5             // Grow by 50% each time
		min_growth_size:    2 * 1024 * 1024 // Minimum 2MB growth
		enable_coalescing:  true
		debug_mode:         true
		trigger_threshold:  0.8 // Trigger GC at 80% usage
	}

	mut collector := gc.new_garbage_collector_with_config(config)
	defer { collector.destroy() }

	println('Initial Configuration:')
	print_collector_status(collector)
	println('')

	// Demo 1: Basic allocation that doesn't trigger growth
	println('=== Demo 1: Basic Allocation ===')
	demo_basic_allocation(mut collector)
	println('')

	// Demo 2: Allocation that triggers heap growth
	println('=== Demo 2: Heap Growth Demo ===')
	demo_heap_growth(mut collector)
	println('')

	// Demo 3: Multiple growth cycles
	println('=== Demo 3: Multiple Growth Cycles ===')
	demo_multiple_growth_cycles(mut collector)
	println('')

	// Demo 4: Mixed allocation patterns
	println('=== Demo 4: Mixed Allocation Patterns ===')
	demo_mixed_allocations(mut collector)
	println('')

	// Demo 5: Incremental collection with growth
	println('=== Demo 5: Incremental Collection ===')
	demo_incremental_collection(mut collector)
	println('')

	// Demo 6: Performance comparison
	println('=== Demo 6: Performance Comparison ===')
	demo_performance_comparison()
	println('')

	// Final status
	println('=== Final Status ===')
	print_collector_status(collector)
}

fn demo_basic_allocation(mut collector gc.GarbageCollector) {
	println('Allocating small objects that fit in initial heap...')

	mut objects := []voidptr{}

	// Allocate 100 small objects
	for i in 0 .. 100 {
		ptr := collector.alloc(64)
		if ptr != unsafe { nil } {
			objects << ptr
			// Write some data to verify allocation works
			unsafe {
				*(&u32(ptr)) = u32(i * 42)
			}
		}
	}

	println('Allocated ${objects.len} objects')
	print_collector_status(collector)

	// Verify data integrity
	mut corrupted := 0
	for i, ptr in objects {
		expected := u32(i * 42)
		actual := unsafe { *(&u32(ptr)) }
		if actual != expected {
			corrupted++
		}
	}
	println('Data integrity check: ${corrupted} corrupted objects')

	// Force collection to clean up
	collector.force_collect()
	println('After garbage collection:')
	print_collector_status(collector)
}

fn demo_heap_growth(mut collector gc.GarbageCollector) {
	println('Allocating large objects to trigger heap growth...')

	mut large_objects := []voidptr{}
	mut growth_stats_before := collector.get_growth_stats()

	// Allocate objects that will fill up the heap
	for i in 0 .. 20 {
		// Allocate 512KB objects
		ptr := collector.alloc(512 * 1024)
		if ptr != unsafe { nil } {
			large_objects << ptr
			println('Allocated object ${i + 1} (512KB)')

			// Check if heap has grown
			growth_stats := collector.get_growth_stats()
			if growth_stats.growth_count > growth_stats_before.growth_count {
				println('🚀 HEAP GROWTH DETECTED!')
				println('  New heap size: ${growth_stats.current_size / (1024 * 1024)}MB')
				println('  Growth #${growth_stats.growth_count}')
				growth_stats_before = growth_stats
			}

			print_collector_status(collector)
		} else {
			println('❌ Allocation failed for object ${i + 1}')
			break
		}
	}

	final_growth_stats := collector.get_growth_stats()
	println('\nGrowth Summary:')
	println('  Initial size: ${collector.config.heap_size / (1024 * 1024)}MB')
	println('  Final size: ${final_growth_stats.current_size / (1024 * 1024)}MB')
	println('  Growth events: ${final_growth_stats.growth_count}')
	println('  Objects allocated: ${large_objects.len}')
}

fn demo_multiple_growth_cycles(mut collector gc.GarbageCollector) {
	println('Creating allocation pressure for multiple growth cycles...')

	mut all_objects := []voidptr{}

	// Create persistent roots to prevent collection
	mut persistent_data := [1000]int{}
	for i in 0 .. persistent_data.len {
		persistent_data[i] = i
	}
	collector.add_root(voidptr(&persistent_data[0]), sizeof(persistent_data))

	// Allocate in waves
	for wave in 0 .. 5 {
		println('\n--- Wave ${wave + 1} ---')
		growth_before := collector.get_growth_stats()

		mut wave_objects := []voidptr{}

		// Allocate varying sizes
		for i in 0 .. 30 {
			size := match i % 3 {
				0 { u32(256 * 1024) } // 256KB
				1 { u32(128 * 1024) } // 128KB
				else { u32(64 * 1024) } // 64KB
			}

			ptr := collector.alloc(size)
			if ptr != unsafe { nil } {
				wave_objects << ptr
			}
		}

		growth_after := collector.get_growth_stats()

		println('Wave ${wave + 1}: ${wave_objects.len} objects allocated')
		if growth_after.growth_count > growth_before.growth_count {
			println('  🚀 Heap grew from ${growth_before.current_size / (1024 * 1024)}MB to ${growth_after.current_size / (1024 * 1024)}MB')
		}

		// Keep half the objects for memory pressure
		for i in 0 .. wave_objects.len / 2 {
			all_objects << wave_objects[i]
		}

		print_collector_status(collector)
	}

	collector.remove_root(voidptr(&persistent_data[0]))
	println('\nFinal multiple growth stats:')
	print_growth_details(collector)
}

fn demo_mixed_allocations(mut collector gc.GarbageCollector) {
	println('Testing mixed small and large allocations...')

	start_time := time.now()
	mut allocations := 0
	mut failed_allocations := 0

	// Mixed allocation pattern
	for round in 0 .. 10 {
		// Small objects burst
		for i in 0 .. 50 {
			ptr := collector.alloc_optimized(32 + u32(i % 64))
			if ptr != unsafe { nil } {
				allocations++
			} else {
				failed_allocations++
			}
		}

		// Medium objects
		for i in 0 .. 10 {
			ptr := collector.alloc(4096 + u32(i * 1024))
			if ptr != unsafe { nil } {
				allocations++
			} else {
				failed_allocations++
			}
		}

		// Large object
		ptr := collector.alloc(1024 * 1024) // 1MB
		if ptr != unsafe { nil } {
			allocations++
		} else {
			failed_allocations++
		}

		// Trigger some collections
		if round % 3 == 0 {
			collector.collect_incremental()
		}

		if round % 5 == 0 {
			print_collector_status(collector)
		}
	}

	elapsed := time.since(start_time)

	println('\nMixed allocation results:')
	println('  Successful allocations: ${allocations}')
	println('  Failed allocations: ${failed_allocations}')
	println('  Time taken: ${elapsed.microseconds()}μs')
	println('  Allocation rate: ${f64(allocations) / elapsed.seconds():.0f} allocs/sec')

	print_growth_details(collector)
}

fn demo_incremental_collection(mut collector gc.GarbageCollector) {
	println('Testing incremental collection with heap growth...')

	// Create some persistent roots
	mut root_data := unsafe { [100]voidptr{} }
	for i in 0 .. 10 {
		root_data[i] = collector.alloc(1024)
	}
	collector.add_root(voidptr(&root_data[0]), sizeof(root_data))

	mut total_allocations := 0

	// Allocation and incremental collection loop
	for cycle in 0 .. 20 {
		// Allocate objects
		for i in 0 .. 25 {
			size := u32(1024 + (i * 512))
			ptr := collector.alloc(size)
			if ptr != unsafe { nil } {
				total_allocations++
			}
		}

		// Incremental collection
		collector.collect_incremental()

		if cycle % 5 == 0 {
			progress := collector.get_incremental_partition_index()
			println('Cycle ${cycle}: ${total_allocations} total allocations, incremental at partition ${progress}')
			print_collector_status(collector)
		}
	}

	collector.remove_root(voidptr(&root_data[0]))

	println('\nIncremental collection completed:')
	println('  Total allocations: ${total_allocations}')
	print_growth_details(collector)
}

fn demo_performance_comparison() {
	println('Comparing fixed vs growable heap performance...')

	// Test with fixed heap
	println('\n--- Fixed Heap Test ---')
	fixed_config := gc.GCConfig{
		heap_size:          32 * 1024 * 1024
		max_heap_size:      32 * 1024 * 1024 // Same as heap_size = no growth
		enable_heap_growth: false
	}

	mut fixed_collector := gc.new_garbage_collector_with_config(fixed_config)
	defer { fixed_collector.destroy() }

	start_time := time.now()
	mut fixed_allocations := performance_test_allocations(mut fixed_collector)
	fixed_time := time.since(start_time)

	println('Fixed heap: ${fixed_allocations} allocations in ${fixed_time.microseconds()}μs')

	// Test with growable heap
	println('\n--- Growable Heap Test ---')
	growable_config := gc.GCConfig{
		heap_size:          8 * 1024 * 1024  // Start smaller
		max_heap_size:      64 * 1024 * 1024 // Can grow larger
		enable_heap_growth: true
		growth_factor:      2.0
	}

	mut growable_collector := gc.new_garbage_collector_with_config(growable_config)
	defer { growable_collector.destroy() }

	start_time_grow := time.now()
	mut growable_allocations := performance_test_allocations(mut growable_collector)
	growable_time := time.since(start_time_grow)

	println('Growable heap: ${growable_allocations} allocations in ${growable_time.microseconds()}μs')

	growth_stats := growable_collector.get_growth_stats()
	println('  Growth events: ${growth_stats.growth_count}')
	println('  Final size: ${growth_stats.current_size / (1024 * 1024)}MB')

	// Compare performance
	println('\n--- Performance Comparison ---')
	if fixed_time > growable_time {
		improvement := f64(fixed_time.microseconds()) / f64(growable_time.microseconds())
		println('Growable heap is ${improvement:.2f}x faster')
	} else {
		overhead := f64(growable_time.microseconds()) / f64(fixed_time.microseconds())
		println('Growable heap has ${overhead:.2f}x overhead')
	}

	success_rate_fixed := f64(fixed_allocations) / 1000.0 * 100
	success_rate_growable := f64(growable_allocations) / 1000.0 * 100

	println('Success rates: Fixed ${success_rate_fixed:.1f}%, Growable ${success_rate_growable:.1f}%')
}

fn performance_test_allocations(mut collector gc.GarbageCollector) int {
	mut successful := 0

	// Allocate 1000 objects of varying sizes
	for i in 0 .. 1000 {
		size := u32(1024 + (i % 10) * 512) // 1KB to 6KB
		ptr := collector.alloc(size)
		if ptr != unsafe { nil } {
			successful++
		}

		// Occasional collection
		if i % 100 == 0 {
			collector.collect_incremental()
		}
	}

	return successful
}

fn print_collector_status(collector &gc.GarbageCollector) {
	stats := collector.get_stats()
	growth_stats := collector.get_growth_stats()

	heap_usage_percent := f64(stats.heap_used) / f64(stats.heap_size) * 100
	max_usage_percent := f64(stats.heap_size) / f64(growth_stats.max_size) * 100

	println('📊 Collector Status:')
	println('   Heap: ${stats.heap_used / 1024}KB / ${stats.heap_size / 1024}KB (${heap_usage_percent:.1f}% used)')
	println('   Max:  ${stats.heap_size / (1024 * 1024)}MB / ${growth_stats.max_size / (1024 * 1024)}MB (${max_usage_percent:.1f}% of max)')
	println('   GC:   ${stats.gc_count} collections, ${stats.total_freed / 1024}KB freed')
	println('   Growth: ${growth_stats.growth_count} events, can grow: ${growth_stats.can_grow}')
}

fn print_growth_details(collector &gc.GarbageCollector) {
	growth_stats := collector.get_growth_stats()
	detailed_stats := collector.get_detailed_stats()

	println('📈 Growth Details:')
	println('   Current size: ${growth_stats.current_size / (1024 * 1024)}MB')
	println('   Maximum size: ${growth_stats.max_size / (1024 * 1024)}MB')
	println('   Growth count: ${growth_stats.growth_count}')
	println('   Growth factor: ${growth_stats.growth_factor}')
	println('   Can still grow: ${growth_stats.can_grow}')
	println('   Fragmentation: ${detailed_stats.fragmentation_ratio:.2f}%')

	// Partition details
	println('   Partitions:')
	for partition_stat in detailed_stats.partition_stats {
		usage_percent := f64(partition_stat.used) / f64(partition_stat.size) * 100
		println('     #${partition_stat.id}: ${partition_stat.used / 1024}KB/${partition_stat.size / 1024}KB (${usage_percent:.1f}%) - ${partition_stat.free_blocks} free blocks')
	}
}
