require "rails_helper"
require "rake"

# Guards I3: city:create mints database URLs with bootstrap superuser
# credentials (see CityProvisioner#database_url_for) — a role that can read
# every other city's database. Real provisioning is a later plan; until then
# this task must refuse to run outside development.
RSpec.describe "city:create rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:create")
  end

  before do
    Rake::Task["city:create"].reenable
  end

  after { City.delete_all }

  it "aborts outside development" do
    allow(Rails.env).to receive(:development?).and_return(false)

    original_stderr, $stderr = $stderr, StringIO.new
    begin
      expect { Rake::Task["city:create"].invoke("naoroda#{SecureRandom.hex(3)}", "Nao Roda", "SP") }
        .to raise_error(SystemExit)
    ensure
      $stderr = original_stderr
    end

    expect(City.where("slug LIKE 'naoroda%'")).to be_empty
  end
end
