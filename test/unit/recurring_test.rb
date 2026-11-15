require_relative "helper"

class RecurringTest < CompilerTest
  def recurring(yaml) = Spinrail::Recurring.new(File.join(app("config/recurring.yml" => yaml), "config/recurring.yml"))

  def slot(schedule) = recurring("t:\n  command: x\n  schedule: #{schedule}\n").tasks.first.slot

  def test_schedules
    assert_equal %(([0, 15, 30, 45].include?(t.min) ? Spinrail::Jobs.minute_slot(t) : "")), slot("every 15 minutes")
    assert_equal %(([0].include?(t.min) ? Spinrail::Jobs.minute_slot(t) : "")), slot("every hour")
    assert_equal "Spinrail::Jobs.interval_slot(t, 30)", slot("every 30 seconds")
    assert_equal "Spinrail::Jobs.interval_slot(t, 420)", slot("every 7 minutes")
    assert_equal %(([30].include?(t.min) && [17].include?(t.hour) ? Spinrail::Jobs.minute_slot(t) : "")), slot("at 5:30pm every day")
    assert_equal %(([0].include?(t.min) && [9].include?(t.hour) && [1].include?(t.wday) ? Spinrail::Jobs.minute_slot(t) : "")),
                 slot("every Monday at 9am")
    assert_equal %(([0].include?(t.min) && [0].include?(t.hour) && ([1].include?(t.day) || [0].include?(t.wday)) ? Spinrail::Jobs.minute_slot(t) : "")),
                 slot('"0 0 1 * 7"')
    assert_equal %(([1, 2, 3, 4, 5].include?(t.wday) ? Spinrail::Jobs.minute_slot(t) : "")), slot('"* * * * mon-fri"')
    assert_equal "Spinrail::Jobs.minute_slot(t)", slot('"* * * * *"')
    assert_raises(Spinrail::CompileError) { slot("every blue moon") }
    assert_raises(Spinrail::CompileError) { slot('"61 * * * *"') }
  end

  def test_tasks_by_environment
    r = recurring(<<~YAML)
      production:
        cleanup:
          class: CleanupJob
          args: [1, "two"]
          priority: 3
          schedule: every day
      everywhere:
        command: Post.delete_all
        schedule: every minute
    YAML
    assert_equal [["cleanup", "production", "CleanupJob", %w[1 two], 3], ["everywhere", "", nil, [], -1]],
                 r.tasks.map { |t| [t.key, t.env, t.job, t.args, t.priority] }
    assert_includes r.to_ruby, %(return Spinrail::Jobs.recur("cleanup", at, "CleanupJob", ["1", "two"], "", 3) if i == 0)
    assert_includes r.to_ruby, %(def self.command_1\n    Post.delete_all\n    nil\n  end)
    assert_equal [%(    return SpinrailRecurring.command_1 if name == "SpinrailRecurring/everywhere")], r.dispatch
  end

  def test_bad_tasks
    assert_raises(Spinrail::CompileError) { recurring("t:\n  class: AJob\n  command: x\n  schedule: every hour\n") }
    assert_raises(Spinrail::CompileError) { recurring("t:\n  class: AJob\n") }
    assert_raises(Spinrail::CompileError) { recurring("t:\n  class: AJob\n  args: [{a: 1}]\n  schedule: every hour\n") }
    assert_raises(Spinrail::CompileError) { build_unknown_job }
  end

  def build_unknown_job
    Spinrail::Build.new(minimal_app("config/recurring.yml" => "t:\n  class: NopeJob\n  schedule: every hour\n")).send(:generate)
  end
end
