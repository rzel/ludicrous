# Helpers for compiling methods and modules.
#
# Most methods here should not be called directly; instead, mixin the
# Ludicrous::JITCompiled module or call Module#ludicrous_compile or
# Module#ludicrous_compile_method to compile a class or method.

module Ludicrous

module JITCompiled
  # Compile a function for which a stub has been installed.
  #
  # Removes the stub if compilation fails.
  #
  # This method should not normally be called by the user.
  #
  # +klass+:: the class or module the method is a member of
  # +method+:: the Method object for the method to compile
  # +name+:: a Symbol with the _current_ name of the method (it gets
  # aliased when the stub is installed)
  # +orig_name+:: a Symbol with the name of the method's stub
  def self.jit_compile_stub(klass, method, name, orig_name)
    tmp_name = "ludicrous__tmp__#{name}".intern

    success = proc { |f|
      # Alias the method so we won't get a warning from the
      # interpreter
      klass.__send__(:alias_method, tmp_name, name)

      # Replace the method with the compiled version
      # TODO: public/private/protected?
      klass.define_jit_method(name, f)
      return true
    }

    failure = proc { |exc|
      # raise # TODO: remove
      # Revert to the original (non-stub) method
      klass.__send__(:alias_method, tmp_name, name)
      klass.__send__(:alias_method, name, orig_name)
      return false
    }

    jit_compile_method(klass, name, method, success, failure)

    # Remove the aliased methods
    klass.__send__(:remove_method, tmp_name)
    klass.__send__(:remove_method, orig_name)
    klass.__send__(:remove_const, "HAVE_LUDICROUS_JIT_STUB__#{name.intern.object_id}")
  end

  # Compile a method right now and replace it with a compiled version.
  #
  # +klass+:: the class or module the method is a member of
  # +name+:: a Symbol with the name of the method
  # +method+:: a Method or UnboundMethod for the method to be compiled
  # +success+:: a callback to be called if compilation is successful
  # +failure+:: a callback to be called if compilation fails
  def self.jit_compile_method(
        klass,
        name,
        method = klass.instance_method(name),
        success = proc { },
        failure = proc { })

    if klass.ludicrous_dont_compile_method(name) then
      Ludicrous.logger.info("Not compiling #{klass}##{name}")
      return
    end

    successful = false
    f = nil

    begin
      Ludicrous.logger.info "Compiling #{klass}##{name}..."
      if klass.const_defined?(:LUDICROUS_OPTIMIZATION_LEVEL) and
         opt = klass.const_get(:LUDICROUS_OPTIMIZATION_LEVEL)
        f = method.ludicrous_compile(opt)
      else
        f = method.ludicrous_compile
      end

      successful = true

    rescue
      Ludicrous.logger.error "#{klass}##{name} failed: #{$!.class}: #{$!} (#{$!.backtrace[0]})"
      failure.call($!)
    end

    if successful then
      Ludicrous.logger.info "#{klass}##{name} compiled"
      success.call(f)
    end
  end

  # Create a proc that when called will compile a method for which a
  # stub has been installed.
  #
  # Returns the proc.
  #
  # This method should not normally be called by the user.
  #
  # +klass+:: the class or module the method is a member of
  # +name+:: a Symbol with the _current_ name of the method (it gets
  # aliased when the stub is installed)
  # +method+:: a Method or UnboundMethod for the method to be compiled
  # +orig_name+:: a Symbol with the name of the method's stub
  def self.compile_proc(klass, method, name, orig_name)
    m = Mutex.new
    compile_proc = proc {
      compiled = false
      if m.try_lock then
        begin
          compiled = Ludicrous::JITCompiled.jit_compile_stub(klass, method, name, orig_name)
        ensure
          m.unlock
        end
      end
      compiled
    }
    return compile_proc
  end

  # Create a JIT::Function that when called will compile the method.
  #
  # Returns the JIT::Function.
  #
  # This method should not normally be called by the user.
  #
  # +klass+:: the class or module the method is a member of
  # +name+:: a Symbol with the _current_ name of the method (it gets
  # aliased when the stub is installed)
  # +method+:: a Method or UnboundMethod for the method to be compiled
  # +orig_name+:: a Symbol with the name of the method's stub
  def self.jit_stub(klass, name, orig_name, method)
    compile_proc = self.compile_proc(klass, method, name, orig_name)

    # TODO: the stub should have the same arity as the original
    # TODO: the stub should have the same access protection as the original
    signature = JIT::Type::RUBY_VARARG_SIGNATURE
    JIT::Context.build do |context|
      function = JIT::Function.compile(context, signature) do |f|
        argc = f.get_param(0)
        argv = f.get_param(1)
        recv = f.get_param(2)

        # Store the args...
        args = f.rb_ary_new4(argc, argv)

        # ... and the passed block for later.
        passed_block = f.value(:OBJECT)
        f.if(f.rb_block_given_p()) {
          passed_block.store f.rb_block_proc()
        }.else {
          passed_block.store f.const(:OBJECT, nil)
        }.end

        unbound_method = f.value(:OBJECT)

        # Check to see if this is a module function
        f.if(f.rb_obj_is_kind_of(recv, klass)) {
          # If it wasn't, go ahead and compile it
          f.if(f.rb_funcall(compile_proc, :call)) {
            # If compilation was successful, then we'll call the
            # compiled method
            unbound_method.store f.rb_funcall(
                klass,
                :instance_method,
                name)
          }.else {
            # Otherwise we'll call the uncompiled method
            unbound_method.store f.const(:OBJECT, method)
          }.end
        }.else {
          sc = f.rb_singleton_class(recv)

          # This is a module function, so fix the module to not have the
          # stub (TODO: perhaps we should just compile the method?)

          f.rb_funcall(
              sc,
              :add_method,
              name.intern,
              f.unwrap_node(method.body),
              Noex::PUBLIC)

          # And prepare to call the uncompiled method
          unbound_method.store f.rb_funcall(
              sc,
              :instance_method,
              name)
        }.end

        # Bind the method we want to call to the receiver
        bound_method = f.rb_funcall(
            unbound_method,
            :bind,
            recv)

        # And call the receiver, passing the given block
        f.insn_return f.block_pass_fcall(
            bound_method,
            :call,
            args,
            passed_block)

        # puts f.dump
      end
      # puts "done"
    end
  end

  # Install a JIT stub for a method that when called will cause the
  # method to be compiled and then called.  If compilation fails, the
  # method is reverted to the original interpreted method.
  #
  # +klass+:: the class or module the method is a member of
  # +name+:: a Symbol with the name of the method
  def self.install_jit_stub(klass, name)
    # Don't install a stub for a stub
    return if name =~ /^ludicrous__orig_tmp__/
    return if name =~ /^ludicrous__stub_tmp__/
    return if name =~ /^ludicrous__tmp__/

    return if klass.const_defined?("HAVE_LUDICROUS_JIT_STUB__#{name.intern.object_id}")

    if klass.ludicrous_dont_compile_method(name) then
      Ludicrous.logger.info("Not compiling #{klass}##{name}")
      return
    end

    begin
      method = klass.instance_method(name)
    rescue NameError
      # TODO: This is a hack
      # How we got here is that the derived class's method added called
      # the original method added, which called install_jit_stub for the
      # base class rather than for the derived class.  We need a better
      # solution than just capturing NameError, but this works for now.
      return
    end

    # Don't try to compile C functions or stubs, or methods for which we
    # aren't likely to see a speed improvement
    # TODO: For some reason we often try to compile jit stubs right
    # after they are installed
    body = method.body
    if Node::CFUNC === body or
       Node::IVAR === body or
       Node::ATTRSET === body then
      Ludicrous.logger.info "Not compiling #{body.class} #{klass}##{name}"
      return
    end

    Ludicrous.logger.info "Installing JIT stub for #{klass}##{name}..."
    tmp_name = "ludicrous__orig_tmp__#{name}".intern
    klass.instance_eval do
      alias_method tmp_name, name
      begin
        stub = Ludicrous::JITCompiled.jit_stub(klass, name, tmp_name, method)
        klass.define_jit_method(name, stub)
        klass.const_set("HAVE_LUDICROUS_JIT_STUB__#{name.intern.object_id}", true)
      rescue
        Ludicrous.logger.error "#{klass}##{name} failed: #{$!.class}: #{$!} (#{$!.backtrace[0]})"
      end
    end
  end

  # Callback when the JITCompiled module is included as a mixin.  Causes
  # stubs to be installed for all methods currently defined and installs
  # a hook so that all future methods will have stubs installed when
  # they are defined.
  def self.append_features(mod)
    if mod.ludicrous_dont_compile then
      Ludicrous.logger.info("Not compiling #{mod}")
      return
    end

    # TODO: not sure if this is necessary, but it can't hurt...
    if mod.instance_eval { defined?(@LUDICROUS_FEATURES_APPENDED) } then
      Ludicrous.logger.info("#{mod} is already JIT-compiled")
      return
    end
    mod.instance_eval { @LUDICROUS_FEATURES_APPENDED = true }

    if not JITCompiled === mod and not JITCompiled == mod then
      # Allows us to JIT-compile the JITCompiled class
      super
    end

    # TODO: We can't compile these right now
    # return if mod == UnboundMethod
    # return if mod == Node::SCOPE
    # return if mod == Node
    # return if mod == MethodSig::Argument

    if mod.const_defined?(:LUDICROUS_PRECOMPILED) and
       mod.const_get(:LUDICROUS_PRECOMPILED) then
      jit_precompile_all_instance_methods(mod)
    else
      install_jit_stubs_for_all_instance_methods(mod)
    end

    install_method_added_jit_hook(mod)
  end

  # Precompile (i.e. compile now) all instance methods in the given
  # module.
  #
  # +mod+:: the module that should be precompiled
  def self.jit_precompile_all_instance_methods(mod)
    if mod.ludicrous_dont_compile then
      Ludicrous.logger.info("Not compiling #{mod}")
      return
    end

    instance_methods = mod.public_instance_methods(false) + \
      mod.protected_instance_methods(false) + \
      mod.private_instance_methods(false)
    instance_methods.each do |name|
      jit_compile_method(mod, name)
    end
  end

  # Install stubs (i.e. compile lazily) all instance methods in the
  # given module.
  #
  # +mod+:: the module that should be lazily compiled
  def self.install_jit_stubs_for_all_instance_methods(mod)
    if mod.ludicrous_dont_compile then
      Ludicrous.logger.info("Not compiling #{mod}")
      return
    end

    instance_methods = mod.public_instance_methods(false) + \
      mod.protected_instance_methods(false) + \
      mod.private_instance_methods(false)
    instance_methods.each do |name|
      install_jit_stub(mod, name)
    end
  end

  # Install a hook so that all future methods added to the given module
  # will have jit stubs installed.
  #
  # +mod+:: the module that should receive the hook
  def self.install_method_added_jit_hook(mod)
    if mod.ludicrous_dont_compile then
      Ludicrous.logger.info("Not compiling #{mod}")
      return
    end

    Ludicrous.logger.info "Installing method_added hook for #{mod}"
    mod_singleton_class = class << mod; self; end
    mod_singleton_class.instance_eval do
      orig_method_added = method(:method_added)
      define_method(:method_added) { |name|
        orig_method_added.call(name)
        break if self != mod
        Ludicrous::JITCompiled.install_jit_stub(mod, name.to_s)
      }
    end
  end
end

end # module Ludicrous

