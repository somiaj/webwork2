(() => {
	// Hover action to show exact value of each bar.
	document.querySelectorAll('.bar_graph_bar').forEach((el) => new bootstrap.Tooltip(el, { trigger: 'hover' }));
})();
