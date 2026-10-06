# spec/tasks/terminology_rake_spec.rb
require "rails_helper"
require "rake"

RSpec.describe "terminology:import rake task" do
  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("terminology:import") }
  before { Rake::Task["terminology:import"].reenable }

  def run(*args)
    out = StringIO.new
    original, $stdout = $stdout, out
    Rake::Task["terminology:import"].invoke(*args)
    out.string
  ensure
    $stdout = original
  end

  it "importa e relata" do
    expect(run("ciap2", "2", Rails.root.join("spec/fixtures/terminology/ciap2").to_s)).to include("ciap2 2 ativa (ciap2_codes: 4)")
  end

  it "falha sai com abort e o motivo" do
    expect { run("ciap2", "2", "/nao/existe") }.to raise_error(SystemExit)
  end
end
