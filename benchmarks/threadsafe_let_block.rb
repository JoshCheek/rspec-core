require 'rspec/core'
require 'rspec/expectations'

# switches between these implementations - https://github.com/rspec/rspec-core/pull/1858/files
# benchmark requested in this PR         - https://github.com/rspec/rspec-core/pull/1858
#
# I ran these from lib root by adding "gem 'benchmark-ips'" to ../Gemfile-custom
# then ran `bundle install --standalone --binstubs bundle/bin`
# then ran `ruby --disable-gems -I lib -I "$PWD/bundle" -r bundler/setup -S benchmarks/threadsafe_let_block.rb`

# The old, non-thread safe implementation, imported from the `master` branch and pared down.
module OriginalNonThreadSafeMemoizedHelpers
  def __memoized
    @__memoized ||= {}
  end

  module ClassMethods
    def let(name, &block)
      # We have to pass the block directly to `define_method` to
      # allow it to use method constructs like `super` and `return`.
      raise "#let or #subject called without a block" if block.nil?
      OriginalNonThreadSafeMemoizedHelpers.module_for(self).__send__(:define_method, name, &block)

      # Apply the memoization. The method has been defined in an ancestor
      # module so we can use `super` here to get the value.
      if block.arity == 1
        define_method(name) { __memoized.fetch(name) { |k| __memoized[k] = super(RSpec.current_example, &nil) } }
      else
        define_method(name) { __memoized.fetch(name) { |k| __memoized[k] = super(&nil) } }
      end
    end
  end

  def self.module_for(example_group)
    get_constant_or_yield(example_group, :LetDefinitions) do
      mod = Module.new do
        include Module.new {
          example_group.const_set(:NamedSubjectPreventSuper, self)
        }
      end

      example_group.const_set(:LetDefinitions, mod)
      mod
    end
  end

  # @private
  def self.define_helpers_on(example_group)
    example_group.__send__(:include, module_for(example_group))
  end

  def self.get_constant_or_yield(example_group, name)
    if example_group.const_defined?(name, (check_ancestors = false))
      example_group.const_get(name, check_ancestors)
    else
      yield
    end
  end
end

class HostBase
  # wires the implementation
  # adds `let(:name) { nil }`
  # returns `Class.new(self) { let(:name) { super() } }`
  def self.prepare_using(memoized_helpers, options={})
    include memoized_helpers
    extend memoized_helpers::ClassMethods
    memoized_helpers.define_helpers_on(self)

    define_method(:initialize, &options[:initialize]) if options[:initialize]
    let(:name) { nil }

    verify_memoizes memoized_helpers, options[:verify]

    Class.new(self) do
      memoized_helpers.define_helpers_on(self)
      let(:name) { super() }
    end
  end

  def self.verify_memoizes(memoized_helpers, additional_verification)
    # Since we're using custom code, ensure it actually memoizes as we expect...
    counter_class = Class.new(self) do
      include RSpec::Matchers
      memoized_helpers.define_helpers_on(self)
      counter = 0
      let(:count) { counter += 1 }
    end
    extend RSpec::Matchers

    instance_1 = counter_class.new
    expect(instance_1.count).to eq(1)
    expect(instance_1.count).to eq(1)

    instance_2 = counter_class.new
    expect(instance_2.count).to eq(2)
    expect(instance_2.count).to eq(2)

    instance_3 = counter_class.new
    instance_3.instance_eval &additional_verification if additional_verification
  end
end

class OriginalNonThreadSafeHost < HostBase
  Subclass = prepare_using OriginalNonThreadSafeMemoizedHelpers
end

class ThreadSafeHost < HostBase
  Subclass = prepare_using RSpec::Core::MemoizedHelpers,
    :initialize => lambda { |*| RSpec.configuration.threadsafe = true; super() },
    :verify     => lambda { |*| expect(__memoized).to be_a_kind_of RSpec::Core::MemoizedHelpers::ThreadsafeMemoized }
end

class ConfigNonThreadSafeHost < HostBase
  Subclass = prepare_using RSpec::Core::MemoizedHelpers,
    :initialize => lambda { |*| RSpec.configuration.threadsafe = false; super() },
    :verify     => lambda { |*| expect(__memoized).to be_a_kind_of RSpec::Core::MemoizedHelpers::NonThreadSafeMemoized }
end

def title(title)
  hr    = "#" * (title.length + 6)
  blank = "#  #{' ' * title.length}  #"
  [hr, blank, "#  #{title}  #", blank, hr]
end

require 'benchmark/ips'

puts title "versions"
puts "RUBY_VERSION             #{RUBY_VERSION}"
puts "RUBY_PLATFORM            #{RUBY_PLATFORM}"
puts "RUBY_ENGINE              #{RUBY_ENGINE}"
puts "ruby -v                  #{`ruby -v`}"
puts "Benchmark::IPS::VERSION  #{Benchmark::IPS::VERSION}"
puts "rspec-core SHA           #{`git log --pretty=format:%H -1`}"
puts

puts title "1 call to let -- each sets the value"
Benchmark.ips do |x|
  x.report("non-threadsafe (original)") { OriginalNonThreadSafeHost.new.name }
  x.report("non-threadsafe (config)  ") { ConfigNonThreadSafeHost.new.name }
  x.report("threadsafe               ") { ThreadSafeHost.new.name }
  x.compare!
end

puts title "10 calls to let -- 9 will find memoized value"
Benchmark.ips do |x|
  x.report("non-threadsafe (original)") do
    i = OriginalNonThreadSafeHost.new
    i.name; i.name; i.name; i.name; i.name
    i.name; i.name; i.name; i.name; i.name
  end

  x.report("non-threadsafe (config)  ") do
    i = ConfigNonThreadSafeHost.new
    i.name; i.name; i.name; i.name; i.name
    i.name; i.name; i.name; i.name; i.name
  end

  x.report("threadsafe               ") do
    i = ThreadSafeHost.new
    i.name; i.name; i.name; i.name; i.name
    i.name; i.name; i.name; i.name; i.name
  end

  x.compare!
end

puts title "1 call to let which invokes super"

Benchmark.ips do |x|
  x.report("non-threadsafe (original)") { OriginalNonThreadSafeHost::Subclass.new.name }
  x.report("non-threadsafe (config)  ") { ConfigNonThreadSafeHost::Subclass.new.name }
  x.report("threadsafe               ") { ThreadSafeHost::Subclass.new.name }
  x.compare!
end

puts title "10 calls to let which invokes super"
Benchmark.ips do |x|
  x.report("non-threadsafe (original)") do
    i = OriginalNonThreadSafeHost::Subclass.new
    i.name; i.name; i.name; i.name; i.name
    i.name; i.name; i.name; i.name; i.name
  end

  x.report("non-threadsafe (config)  ") do
    i = ConfigNonThreadSafeHost::Subclass.new
    i.name; i.name; i.name; i.name; i.name
    i.name; i.name; i.name; i.name; i.name
  end

  x.report("threadsafe               ") do
    i = ThreadSafeHost::Subclass.new
    i.name; i.name; i.name; i.name; i.name
    i.name; i.name; i.name; i.name; i.name
  end

  x.compare!
end

__END__

##############
#            #
#  versions  #
#            #
##############
RUBY_VERSION             2.2.0
RUBY_PLATFORM            x86_64-darwin13
RUBY_ENGINE              ruby
ruby -v                  ruby 2.2.0p0 (2014-12-25 revision 49005) [x86_64-darwin13]
Benchmark::IPS::VERSION  2.1.1
rspec-core SHA           048643ba3873c2f55d3bc5dc31334f080f6cbeaf

##########################################
#                                        #
#  1 call to let -- each sets the value  #
#                                        #
##########################################
Calculating -------------------------------------
non-threadsafe (original)
                        54.820k i/100ms
non-threadsafe (config)
                        32.292k i/100ms
threadsafe
                        21.787k i/100ms
-------------------------------------------------
non-threadsafe (original)
                        837.649k (± 6.8%) i/s -      4.221M
non-threadsafe (config)
                        422.334k (± 6.9%) i/s -      2.131M
threadsafe
                        249.748k (± 5.0%) i/s -      1.264M

Comparison:
non-threadsafe (original):   837648.9 i/s
non-threadsafe (config)  :   422334.3 i/s - 1.98x slower
threadsafe               :   249747.7 i/s - 3.35x slower

###################################################
#                                                 #
#  10 calls to let -- 9 will find memoized value  #
#                                                 #
###################################################
Calculating -------------------------------------
non-threadsafe (original)
                        28.190k i/100ms
non-threadsafe (config)
                        21.302k i/100ms
threadsafe
                        15.471k i/100ms
-------------------------------------------------
non-threadsafe (original)
                        342.177k (± 7.1%) i/s -      1.720M
non-threadsafe (config)
                        242.997k (± 5.5%) i/s -      1.214M
threadsafe
                        173.325k (± 6.1%) i/s -    866.376k

Comparison:
non-threadsafe (original):   342176.8 i/s
non-threadsafe (config)  :   242997.4 i/s - 1.41x slower
threadsafe               :   173325.4 i/s - 1.97x slower

#######################################
#                                     #
#  1 call to let which invokes super  #
#                                     #
#######################################
Calculating -------------------------------------
non-threadsafe (original)
                        41.413k i/100ms
non-threadsafe (config)
                        27.500k i/100ms
threadsafe
                        17.971k i/100ms
-------------------------------------------------
non-threadsafe (original)
                        599.117k (± 5.8%) i/s -      3.023M
non-threadsafe (config)
                        349.744k (± 5.9%) i/s -      1.760M
threadsafe
                        201.316k (± 6.3%) i/s -      1.006M

Comparison:
non-threadsafe (original):   599117.3 i/s
non-threadsafe (config)  :   349744.0 i/s - 1.71x slower
threadsafe               :   201316.2 i/s - 2.98x slower

#########################################
#                                       #
#  10 calls to let which invokes super  #
#                                       #
#########################################
Calculating -------------------------------------
non-threadsafe (original)
                        23.086k i/100ms
non-threadsafe (config)
                        18.249k i/100ms
threadsafe
                        13.180k i/100ms
-------------------------------------------------
non-threadsafe (original)
                        290.688k (± 6.4%) i/s -      1.454M
non-threadsafe (config)
                        214.459k (± 6.4%) i/s -      1.077M
threadsafe
                        148.218k (± 4.9%) i/s -    751.260k

Comparison:
non-threadsafe (original):   290688.4 i/s
non-threadsafe (config)  :   214459.2 i/s - 1.36x slower
threadsafe               :   148218.3 i/s - 1.96x slower
