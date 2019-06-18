begin
  require 'active_support'
  require 'active_support/core_ext'
rescue NameError
  warn 'active_support is not available. AppMap execution will continue optimistically without it...'
end

require 'appmap/version'

module AppMap
  class << self
    # Simplified entry point to inspect code for features.
    def inspect(config)
      require 'appmap/inspect'
      features = config.map(&AppMap::Inspect.method(:detect_features))
      features = features.map(&:reparent)
      features.each(&:prune)
    end
  end
end
