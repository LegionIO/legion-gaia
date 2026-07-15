# frozen_string_literal: true

# Polyfill Numeric#max for specs — the production runtime provides this via
# a loaded extension, but the isolated spec env does not.
class Numeric
  unless method_defined?(:max)
    def max(other)
      [self, other].max
    end
  end

  unless method_defined?(:min)
    def min(other)
      [self, other].min
    end
  end
end
