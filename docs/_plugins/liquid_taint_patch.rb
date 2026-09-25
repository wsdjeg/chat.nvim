# frozen_string_literal: true

# Liquid 4.0.x is pinned by Jekyll 3.9 (github-pages) and still calls
# String#tainted? -- a method Ruby removed in 3.2 -- from
# Liquid::Variable#taint_check while rendering:
#
#   liquid-4.0.3/lib/liquid/variable.rb:124: undefined method 'tainted?'
#     for an instance of String (NoMethodError)
#       return unless obj.tainted?
#
# taint_check only ever emitted a deprecation warning on legacy Rubies, so
# stubbing it out is behaviour-preserving. Drop this file once the docs
# build moves off Jekyll 3.9 / Liquid 4.

if defined?(Liquid::Variable) && !"".respond_to?(:tainted?)
  Liquid::Variable.prepend(Module.new do
    def taint_check(_obj)
      # Ruby >= 3.2: taint is gone, nothing to check.
    end
  end)
end

