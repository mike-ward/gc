import gc

struct Node {
mut:
	value int
	next  &Node = unsafe { nil }
}

fn main() {
	println('V Garbage Collector Example')
	println('============================')

	// Initialize garbage collector with 10MB heap
	mut collector := gc.new_garbage_collector(10 * 1024 * 1024)
	defer { collector.destroy() }

	println('Initial heap size: ${collector.heap_size()} bytes')
	println('Number of partitions: ${collector.num_partitions()}')

	// Example 1: Simple allocations
	println('\nExample 1: Simple allocations')
	for _ in 0 .. 10 {
		ptr := collector.alloc(64)
		if ptr != unsafe { nil } {
			println('Allocated 64 bytes at address: ${ptr}')
		}
	}

	stats := collector.get_stats()
	println('Total allocated: ${stats.total_allocated} bytes')

	// Example 2: Create linked list (will become garbage)
	println('\nExample 2: Creating linked list')
	create_linked_list(mut collector, 100)

	stats_before_gc := collector.get_stats()
	println('Before GC - Allocated: ${stats_before_gc.total_allocated}, Freed: ${stats_before_gc.total_freed}')

	// Force garbage collection
	collector.force_collect()

	stats_after_gc := collector.get_stats()
	println('After GC - Allocated: ${stats_after_gc.total_allocated}, Freed: ${stats_after_gc.total_freed}')
	println('GC runs: ${stats_after_gc.gc_count}')

	// Example 3: Add persistent root
	println('\nExample 3: Persistent root')
	mut persistent_data := [10]int{}
	for i in 0 .. persistent_data.len {
		persistent_data[i] = i * i
	}

	collector.add_root(voidptr(&persistent_data[0]), sizeof(persistent_data))

	// Allocate more memory
	for _ in 0 .. 50 {
		collector.alloc(128)
	}

	collector.force_collect()

	final_stats := collector.get_stats()
	println('Final stats - GC runs: ${final_stats.gc_count}')
	println('Heap utilization: ${f64(final_stats.heap_used) / f64(final_stats.heap_size) * 100:.1f}%')
}

fn create_linked_list(mut collector gc.GarbageCollector, count int) {
	mut head := unsafe { &Node(nil) }

	for i in 0 .. count {
		// Allocate node (this will become garbage after function returns)
		node_ptr := collector.alloc(sizeof(Node))
		if node_ptr != unsafe { nil } {
			mut node := unsafe { &Node(node_ptr) }
			unsafe {
				node.value = i
				node.next = head
			}
			head = node
		}
	}

	println('Created linked list with ${count} nodes')
	// head goes out of scope here, making the entire list eligible for GC
}
