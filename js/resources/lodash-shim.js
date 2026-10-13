// The seven lodash functions dTree calls, so the full library does not have to be shipped.
var _ = (function() {
	function isPlainObject(value) {
		return Object.prototype.toString.call(value) === '[object Object]';
	}

	// True when every property in pattern is found, with the same value, in value.
	function matches(value, pattern) {
		return Object.keys(pattern).every(function(key) {
			if (isPlainObject(pattern[key])) {
				return value != null && value[key] != null && matches(value[key], pattern[key]);
			}
			return value != null && value[key] === pattern[key];
		});
	}

	function defaultsDeep(target, defaults) {
		Object.keys(defaults).forEach(function(key) {
			if (target[key] === undefined) {
				target[key] = isPlainObject(defaults[key]) ? defaultsDeep({}, defaults[key]) : defaults[key];
			} else if (isPlainObject(target[key]) && isPlainObject(defaults[key])) {
				defaultsDeep(target[key], defaults[key]);
			}
		});
		return target;
	}

	return {
		bind: function(fn, context) {
			return fn.bind(context);
		},
		defaultsDeep: defaultsDeep,
		filter: function(list, predicate) {
			return (list || []).filter(predicate);
		},
		find: function(list, pattern) {
			return (list || []).find(function(item) {
				return matches(item, pattern);
			});
		},
		// Like lodash, tolerates a missing list and stops when the callback returns false.
		forEach: function(list, callback) {
			for (var i = 0; list && i < list.length; i++) {
				if (callback(list[i], i, list) === false) {
					break;
				}
			}
			return list;
		},
		get: function(object, path, fallback) {
			var value = path.split('.').reduce(function(current, key) {
				return current == null ? undefined : current[key];
			}, object);
			return value === undefined ? fallback : value;
		},
		map: function(list, iteratee) {
			return (list || []).map(iteratee);
		}
	};
})();
