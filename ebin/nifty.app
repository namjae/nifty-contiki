{
	application,
	nifty,
	[
		{description,
			"NIF interface generator"}, 
		{vsn,
			"0.1"},
		{modules, [
			nifty, 
			nifty_clangparse,
			nifty_cooja,
			nifty_cooja_recorder,
			nifty_compiler,
			nifty_filters,
			nifty_rebar,
			nifty_remote,
			nifty_remotecall,
			nifty_tags,
			nifty_types,
			nifty_utils,
			nifty_xmlhelper]},
		{applications,[kernel,stdlib,compile]}
	]
}.
