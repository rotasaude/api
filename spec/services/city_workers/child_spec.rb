require "rails_helper"

# Plano 5 (spike 2): o filho de uma unidade liga o Solid Queue do PROCESSO INTEIRO
# ao banco certo antes de entrar no supervisor. Roda de verdade num fork, e o
# resultado volta por um pipe. O fork abre conexões novas, então a cidade precisa
# estar comitada (sem transação de fixture).
RSpec.describe CityWorkers::Child do
  self.use_transactional_tests = false

  let(:slug) { "filho#{SecureRandom.hex(3)}" }
  let!(:city) do
    City.create!(slug: slug, name: "Filho", status: "active", schema_version: CitySchema.expected_version.to_s,
                 database_url: city_database_url("rota_saude_test_city_b"), encryption_key: SecureRandom.hex(32))
  end

  after do
    CityConnection.forget(city.shard)
    City.where(id: city.id).delete_all
  end

  # Roda `prepare` num fork, numa thread nova (sem o connected_to que o harness
  # empilhou na thread principal), e devolve o que o processo filho enxerga.
  def prepare_in_fork(unit)
    reader, writer = IO.pipe
    pid = Process.fork do
      reader.close
      result = Thread.new do
        options = described_class.prepare(unit)
        {
          "context" => CityWorkers::Context.city_slug,
          "queue_database" => SolidQueue::Job.connection_db_config.database,
          "queue_database_other_thread" => Thread.new { SolidQueue::Job.connection_db_config.database }.value,
          "config_file" => options[:config_file].to_s.delete_prefix("#{Rails.root}/"),
          "recurring_schedule_file" => options[:recurring_schedule_file].to_s.delete_prefix("#{Rails.root}/"),
          "group_leader" => Process.getpgrp == Process.pid
        }
      rescue StandardError => e
        { "error" => e.class.name }
      end.value
      writer.write(result.to_json)
      writer.close
      exit!(0)
    end
    writer.close
    output = reader.read
    Process.wait(pid)
    JSON.parse(output)
  end

  it "binds the whole process's Solid Queue to the city's database and marks the process's city" do
    expect(prepare_in_fork(CityWorkers::Unit.city(slug))).to eq(
      "context" => slug,
      "queue_database" => "rota_saude_test_city_b",
      "queue_database_other_thread" => "rota_saude_test_city_b",
      "config_file" => "config/queue.yml",
      "recurring_schedule_file" => "config/recurring.yml",
      "group_leader" => true
    )
  end

  it "keeps the platform supervisor on the platform database, with no city" do
    expect(prepare_in_fork(CityWorkers::Unit.platform)).to include(
      "context" => nil,
      "queue_database" => "rota_saude_platform_test",
      "queue_database_other_thread" => "rota_saude_platform_test",
      "config_file" => "config/queue_platform.yml",
      "recurring_schedule_file" => "config/recurring_platform.yml"
    )
  end

  it "refuses a city that is no longer active or whose schema is behind" do
    city.update!(status: "suspended")
    expect(prepare_in_fork(CityWorkers::Unit.city(slug))).to eq("error" => "CityWorkers::Child::CityUnavailable")

    city.update!(status: "active", schema_version: nil)
    expect(prepare_in_fork(CityWorkers::Unit.city(slug))).to eq("error" => "CityWorkers::Child::CityUnavailable")
  end
end
