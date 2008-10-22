require 'ludicrous/yarv_vm'
require 'internal/tag'

class RubyVM
  class InstructionSequence
    def ludicrous_compile(function, env)
      puts self.disasm

      if self.catch_table.size > 0 then
        self.ludicrous_compile_body_with_catch(function, env)
      else
        self.ludicrous_compile_body(function, env)
      end
    end

    # TODO: This method belongs elsewhere
    def push_tag(function, env)
      tag = Ludicrous::VMTag.create(function)
      tag.tag = function.const(JIT::Type::INT, 0)
      tag.prev = function.ruby_current_thread_tag()
      function.ruby_set_current_thread_tag(tag.ptr)
      return tag
    end

    def pop_tag(function, env, tag)
      function.ruby_set_current_thread_tag(tag.prev)
    end

    # TODO: This method belongs elsewhere
    def exec_tag(function, env)
      # TODO: _setjmp may or may not be right for this platform
      jmp_buf = function.ruby_current_thread_jmp_buf()
      return function._setjmp(jmp_buf)
    end

    def ludicrous_compile_body_with_catch(function, env)
      sorted_catch_table = self.catch_table.sort { |lhs, rhs|
        [ lhs.start, lhs.end ] <=> [ rhs.start, rhs.end ]
      }

      instructions = self.entries
      idx = 0

      sorted_catch_table.each do |catch_entry|
        while env.pc.offset < catch_entry.start do
          instruction = instructions[idx]
          ludicrous_compile_next_instruction(function, env, instruction)
          idx += 1
        end

        ludicrous_compile_catch_entry(function, env, catch_entry) do
          # TODO: I don't know if this should be < or <=.  If <, then
          # REDO fails to compile (because the LEAVE instruction at the
          # end is missed, so the stack isn't empty when it hits the
          # branch)
          while env.pc.offset <= catch_entry.end do
            instruction = instructions[idx]
            ludicrous_compile_next_instruction(function, env, instruction)
            idx += 1
          end
        end
      end

      while idx < instructions.length
        instruction = instructions[idx]
        ludicrous_compile_next_instruction(function, env, instruction)
        idx += 1
      end
    end

    CATCH_TYPE_TAG = Hash.new { |h, k|
      raise "No such catch type #{k}"
    }

    CATCH_TYPE_TAG.update({
      CATCH_TYPE_RESCUE => Tag::RAISE,
      CATCH_TYPE_BREAK  => Tag::BREAK,
      CATCH_TYPE_REDO   => Tag::REDO,
      CATCH_TYPE_NEXT   => Tag::NEXT,
      CATCH_TYPE_RETRY  => Tag::RETRY,
    })

    def ludicrous_compile_catch_entry(function, env, catch_entry)
      catch_tag = function.const(
          JIT::Type::INT,
          CATCH_TYPE_TAG[catch_entry.type])
      zero = function.const(JIT::Type::INT, 0)

      tag = push_tag(function, env)
      state = exec_tag(function, env)
      function.debug_printf("state=%d\n", state.int2fix)
      function.if(state == zero) {
      function.debug_printf("yield\n")
        yield
      function.debug_printf("yield done\n")
      }.end
      pop_tag(function, env, tag)
      function.debug_printf("state=%d\n", state.int2fix)

      case catch_entry.type
      when CATCH_TYPE_RESCUE
        function.if(state == zero) {
        }.elsif(state == catch_tag) {
          if catch_entry.sp != 0 then
            raise "Can't handle catch entry with sp=#{sp}"
          end
          catch_entry_env = Ludicrous::YarvEnvironment.new(
              function,
              env.options,
              env.cbase,
              env.scope,
              catch_entry.iseq)
          catch_entry.iseq.ludicrous_compile(function, catch_entry_env)
          # TODO: reset errinfo
          env.branch(catch_entry.cont)
        }.else {
          function.rb_jump_tag(state)
        }.end

      when CATCH_TYPE_ENSURE
        raise "Unknown catch type 'ensure'"

      when CATCH_TYPE_RETRY
        function.if(state == zero) {
        }.elsif(state == catch_tag) {
          env.branch(catch_entry.cont)
        }.else {
          function.rb_jump_tag(state)
        }.end

      when CATCH_TYPE_BREAK, CATCH_TYPE_REDO, CATCH_TYPE_NEXT
        function.if(state == zero) {
        }.elsif(state == catch_tag) {
          env.branch(catch_entry.cont)
        }.else {
          function.rb_jump_tag(state)
        }.end
        
      end
    end

    def ludicrous_compile_body(function, env)
      self.each do |instruction|
        ludicrous_compile_next_instruction(function, env, instruction)
      end
    end

    def ludicrous_compile_next_instruction(function, env, instruction)
      # env.stack.sync_sp
      function.debug_print_msg(
          "#{'%04d' % env.pc.offset} " +
          "#{'%x' % self.object_id} " +
          "#{instruction.inspect}")
      # function.debug_inspect_object instruction
      env.make_label
      env.pc.advance(instruction.length)
      instruction.ludicrous_compile(function, env)
      # env.stack.sync_sp
      # env.stack.debug_inspect
    end

    def ludicrous_compile_catch_table(function, env)
    end
  end
end

