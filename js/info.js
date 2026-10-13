// Close the info panel from its close button, or by clicking anywhere outside it and the tree nodes.
document.addEventListener('click', function(event) {
	var info = document.querySelector('.info');
	if (!info) {
		return;
	}
	if (event.target.closest('#close') || !event.target.closest('.info, foreignObject')) {
		info.remove();
	}
});
