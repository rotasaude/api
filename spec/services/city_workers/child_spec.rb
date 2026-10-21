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
                 database_url: city_database_url(TEST_CITY_B_DATABASE), encryption_key: SecureRandom.hex(32))
  end

  after do
    CityConnection.forget(city.shard)
    City.where(id: city.id).delete_all
  end

  # Roda `prepare` num fork, numa thread nova (sem o connected_to que o harness
  # empilhou na thread principal), e devolve o que o processo filho enxerga.
  #
  # Timeout de leitura (Minor 3, fix round 1): sem ele, um filho que trava antes
  # de escrever no pipe pendura o exemplo para sempre. `ensure` mata e espera o
  # fork sempre que o caminho normal não chegou a fazer o próprio Process.wait.
  def prepare_in_fork(unit)
    reader, writer = IO.pipe
    waited = false
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

    raise "timed out waiting for city_workers child (pid #{pid}) to answer" unless IO.select([ reader ], nil, nil, 10)

    output = reader.read
    Process.wait(pid)
    waited = true
    JSON.parse(output)
  ensure
    reader.close unless reader.closed?
    unless waited
      begin
        Process.kill("KILL", pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  it "binds the whole process's Solid Queue to the city's database and marks the process's city" do
    expect(prepare_in_fork(CityWorkers::Unit.city(slug))).to eq(
      "context" => slug,
      "queue_database" => TEST_CITY_B_DATABASE,
      "queue_database_other_thread" => TEST_CITY_B_DATABASE,
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

  # Os exemplos de fork acima provam o comportamento, mas um fork que sai com
  # exit! não devolve cobertura. Estes repetem os ramos no próprio processo, com
  # dublês para o que mexeria no processo do teste (grupo e conexão do Solid Queue).
  describe ".prepare (in process)" do
    before do
      allow(Process).to receive(:setpgid)
      allow(CityConnection).to receive(:ensure_pool)
      allow(SolidQueue::Record).to receive(:establish_connection)
    end

    after { CityWorkers::Context.city_slug = nil }

    it "points Solid Queue at the city's database and marks the process's city" do
      options = described_class.prepare(CityWorkers::Unit.city(slug))

      expect(Process).to have_received(:setpgid).with(0, 0)
      expect(CityConnection).to have_received(:ensure_pool).with(city)
      expect(SolidQueue::Record).to have_received(:establish_connection)
        .with(having_attributes(database: TEST_CITY_B_DATABASE))
      expect(CityWorkers::Context.city_slug).to eq(slug)
      expect(options).to eq(mode: :fork, config_file: Rails.root.join("config/queue.yml"),
                            recurring_schedule_file: Rails.root.join("config/recurring.yml"))
    end

    it "refuses an unknown or unavailable city before touching any connection" do
      city.update!(status: "suspended")

      expect { described_class.prepare(CityWorkers::Unit.city(slug)) }.to raise_error(described_class::CityUnavailable)
      expect { described_class.prepare(CityWorkers::Unit.city("naoexiste")) }
        .to raise_error(described_class::CityUnavailable)
      expect(SolidQueue::Record).not_to have_received(:establish_connection)
      expect(CityWorkers::Context.city_slug).to be_nil
    end
  end

  describe ".run" do
    let(:unit) { CityWorkers::Unit.city(slug) }

    before { allow(described_class).to receive(:start_watchdog) }

    it "starts the watchdog for the manager and enters the supervisor with the prepared options" do
      allow(described_class).to receive(:prepare).with(unit).and_return(mode: :fork)
      allow(SolidQueue::Supervisor).to receive(:start)

      described_class.run(unit, manager_pid: 777)

      expect(described_class).to have_received(:start_watchdog).with(777)
      expect(SolidQueue::Supervisor).to have_received(:start).with(mode: :fork)
    end

    it "exits with one redacted line, no backtrace, when the boot fails" do
      allow(described_class).to receive(:prepare)
        .and_raise(described_class::CityUnavailable, "postgres://rota:segredo@db/x fora do ar")
      allow(described_class).to receive(:exit!)

      expect { described_class.run(unit, manager_pid: 777) }
        .to output("[city_workers] city:#{slug}: não subiu (CityWorkers::Child::CityUnavailable): " \
                   "postgres://***@db/x fora do ar\n").to_stderr
      expect(described_class).to have_received(:exit!).with(1)
    end
  end

  describe ".start_watchdog" do
    before { stub_const("CityWorkers::Child::WATCHDOG_INTERVAL", 0.01) }

    it "sends TERM to its own process once the manager is no longer the parent" do
      allow(described_class).to receive(:orphaned?).with(777).and_return(false, true)
      allow(Process).to receive(:kill)

      expect(described_class.start_watchdog(777).join(2)).to be_truthy
      expect(described_class).to have_received(:orphaned?).twice
      expect(Process).to have_received(:kill).with("TERM", Process.pid).once
    end
  end

  # Important 2 (fix round 1): o watchdog em si roda numa thread com sleep(1) —
  # não vale a pena forkar uma árvore só para testar isso. O que importa testar
  # é a checagem pura que ele faz a cada volta.
  describe ".orphaned?" do
    it "is false while the given pid is still this process's parent" do
      expect(described_class.orphaned?(Process.ppid)).to be(false)
    end

    it "is true once the parent stops being that pid" do
      expect(described_class.orphaned?(Process.ppid + 1)).to be(true)
    end
  end
end
