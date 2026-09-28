require "rails_helper"
require "rake"

RSpec.describe "city:territory:seed rake task" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("city:territory:seed")
  end

  before do
    Rake::Task["city:territory:seed"].reenable
    Rake::Task["city:territory:seed:all"].reenable
  end

  after { CityCatalog.reset_cache! }

  # A mesma linha de catálogo que os request specs usam (city_request_auth.rb):
  # CityConnection.with(city) cai na conexão de TEST_CITY_A da transação.
  let!(:city) do
    City.find_by(slug: TEST_CITY_A.slug) ||
      City.create!(slug: TEST_CITY_A.slug, name: TEST_CITY_A.name, status: "active",
                   database_url: TEST_CITY_A.database_url, encryption_key: TEST_CITY_A.encryption_key,
                   schema_version: CitySchema.expected_version.to_s)
  end
  let(:dir) { Pathname(Dir.mktmpdir) }
  after { FileUtils.remove_entry(dir) }

  def run(task, *args)
    out = StringIO.new
    original_stdout, $stdout = $stdout, out
    original_stderr, $stderr = $stderr, StringIO.new
    Rake::Task[task].invoke(*args)
    out.string
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  it "carrega a semente da cidade, relata, e a segunda vez não cria nada" do
    path = dir.join("#{city.slug}.yml")
    path.write("neighborhoods:\n  - name: Centro\n    key: centro\n  - name: Batel\n    key: batel\n")
    allow(Territory::Seed).to receive(:path_for).with(city.slug).and_return(path)

    expect(run("city:territory:seed", city.slug)).to include("2 criados, 0 já existentes, 0 avisos")
    expect(Neighborhood.pluck(:name)).to contain_exactly("Centro", "Batel")

    Rake::Task["city:territory:seed"].reenable
    expect(run("city:territory:seed", city.slug)).to include("0 criados, 2 já existentes, 0 avisos")
  end

  it "cidade sem arquivo: mensagem e saída sem erro" do
    allow(Territory::Seed).to receive(:path_for).and_return(dir.join("nao-existe.yml"))
    expect(run("city:territory:seed", city.slug)).to include("sem semente")
  end

  it ":all passa por toda cidade active/suspended" do
    path = dir.join("todas.yml")
    path.write("neighborhoods:\n  - name: Centro\n    key: centro\n")
    allow(Territory::Seed).to receive(:path_for).and_return(path)
    allow(City).to receive(:where).and_call_original
    allow(City).to receive(:where).with(status: %w[active suspended]).and_return(City.where(id: city.id))

    expect(run("city:territory:seed:all")).to include("#{city.slug}: 1 criados")
  end

  it "slug inexistente: aborta" do
    expect { run("city:territory:seed", "nao-existe") }.to raise_error(SystemExit)
  end
end
