require "rails_helper"

# Módulo 33 (ADR 0051; Desvio 4): a trava cidadão → manifestação e o
# expected_state. Threads reais contra TEST_CITY_A (sem fixture transacional):
# a prova de que uma transação esperou vem de pg_stat_activity, nunca de sleep.
RSpec.describe Ombudsman::Lock do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |table| %w[schema_migrations ar_internal_metadata].include?(table) }
              .select { |table| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)})") }
  end

  before do
    @ids = in_city do
      @empty = empty_tables
      citizen = web_citizen!
      { citizen: citizen.id, manifestation: raw_manifestation!(citizen: citizen).id }
    end
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError, ScriptError # join relança o erro da thread; a limpeza abaixo tem de rodar sempre
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        @empty.to_a.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
  end

  # Segura o que `work` travou até `release`, sem commitar.
  def hold(&work)
    holding = Queue.new
    threads << Thread.new do
      Thread.current.report_on_exception = false
      in_city do
        ApplicationRecord.transaction do
          work.call
          holding << true
          release.pop(timeout: 10) or raise "timeout esperando release"
        end
      end
    end
    holding.pop(timeout: 5) or raise "a primeira transação não segurou a trava"
  end

  def lock_in_thread(out)
    threads << thread = Thread.new do
      Thread.current.report_on_exception = false
      out << in_city { ApplicationRecord.transaction { described_class.manifestation!(@ids[:manifestation])&.citizen_id } }
    rescue StandardError => e
      out << e
    end
    thread
  end

  describe ".manifestation!" do
    it "devolve a manifestação travada; id inexistente devolve nil" do
      in_city do
        ApplicationRecord.transaction do
          expect(described_class.manifestation!(@ids[:manifestation]).id).to eq(@ids[:manifestation])
          expect(described_class.manifestation!(SecureRandom.uuid)).to be_nil
        end
      end
    end

    it "com o cidadão travado FOR UPDATE por outra conexão, espera até ela terminar" do
      hold { Citizen.lock("FOR UPDATE").find(@ids[:citizen]) }

      out = Queue.new
      thread = lock_in_thread(out)
      expect(wait_for_lock_wait).to be(true)
      expect(thread.join(0.3)).to be_nil

      release << true
      expect(thread.join(10)).to be(thread)
      expect(out.pop(timeout: 5)).to eq(@ids[:citizen])
    end

    it "se a exclusão anulou o citizen_id no intervalo, recomeça sem o cidadão" do
      hold do
        Citizen.lock("FOR UPDATE").find(@ids[:citizen])
        OmbudsmanManifestation.find(@ids[:manifestation]).update_columns(citizen_id: nil)
      end

      out = Queue.new
      thread = lock_in_thread(out)
      expect(wait_for_lock_wait).to be(true)

      release << true
      expect(thread.join(10)).to be(thread)
      expect(out.pop(timeout: 5)).to be_nil
    end
  end

  describe ".check" do
    let(:manifestation) { OmbudsmanManifestation.new(state: "in_analysis") }

    it "estado igual ao atual: nada a recusar" do
      expect(described_class.check(manifestation, "in_analysis")).to be_nil
    end

    it "expected_state diferente do atual: 409 manifestation_changed" do
      result = described_class.check(manifestation, "received")
      expect(result).to be_failure
      expect(result.reason).to eq(:manifestation_changed)
    end

    it "ausente, malformado ou fora de STATES: invalid_request com path expected_state" do
      [ nil, "", 3, "bogus", [ "in_analysis" ] ].each do |value|
        result = described_class.check(manifestation, value)
        expect(result.reason).to eq(:invalid_request)
        expect(result.details).to include(path: "expected_state")
        expect(result.details[:problems]).to eq([ { error: "invalid_request", path: "expected_state" } ])
      end
    end
  end
end
