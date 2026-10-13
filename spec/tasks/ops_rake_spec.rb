require "rails_helper"
require "rake"

# api#74: a conta de conexões impressa pela rake, e o uso quando falta o número.
RSpec.describe "ops rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("ops:connection_budget")
  end

  def invoke(*args)
    Rake::Task["ops:connection_budget"].reenable
    original_stdout, $stdout = $stdout, StringIO.new
    original_stderr, $stderr = $stderr, StringIO.new
    status = nil
    begin
      Rake::Task["ops:connection_budget"].invoke(*args)
    rescue SystemExit => e
      status = e.status
    end
    [ $stdout.string, $stderr.string, status ]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  it "prints the budget per part and the total for the given cities" do
    out, = invoke("5")
    expect(out).to match(/web/i)
    expect(out).to match(/total.*777/im)
  end

  it "prints the usage and exits 1 without a positive number of cities" do
    [ [], [ "0" ], [ "x" ] ].each do |args|
      _, err, status = invoke(*args)
      expect(status).to eq(1)
      expect(err).to include("uso: bin/rails 'ops:connection_budget[5]'")
    end
  end
end
