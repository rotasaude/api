require "rails_helper"

# Spec da API de manutenção §9: com poderes totais, o que resta é registrar quem
# fez o quê — e ninguém, nem o superusuário, reescreve esse registro.
RSpec.describe MaintenanceAudit do
  let(:maintainer) { Maintainer.create!(email_address: "aud-#{SecureRandom.hex(3)}@rotasaude.app") }

  it "records an event with actor, module, outcome and correlation id" do
    correlation_id = described_class.record(
      "maintenance.session.started", outcome: "ok", maintainer_id: maintainer.id,
      credential: described_class.credential_for(session: "s-1"), module_name: "session"
    )

    event = PlatformEvent.order(:created_at).last
    expect(event.name).to eq("maintenance.session.started")
    expect(event.payload).to include("outcome" => "ok", "module" => "session",
                                     "maintainer_id" => maintainer.id, "correlation_id" => correlation_id)
    expect(event.payload.fetch("credential")).to eq({ "kind" => "session" })
  end

  it "never carries the maintainer's e-mail, only the id (Ruling R18)" do
    # Como o resto da guarda R18 (platform_event_payload_guard_spec.rb): a
    # mensagem de ActiveRecord::RecordInvalid depende de tradução pt-BR que
    # este app não define, então a asserção lê errors[:payload], não .message.
    expect do
      described_class.record("maintenance.session.started", outcome: "ok", maintainer_id: maintainer.id,
                             credential: { "kind" => "session" }, module_name: "session",
                             email: maintainer.email_address)
    end.to raise_error(ActiveRecord::RecordInvalid) { |e| expect(e.record.errors[:payload].join).to include("email") }
  end

  it "refuses an undeclared name and an unknown outcome" do
    expect do
      described_class.record("maintenance.whatever.done", outcome: "ok", maintainer_id: maintainer.id,
                             credential: { "kind" => "session" }, module_name: "session")
    end.to raise_error(ArgumentError, /maintenance\.whatever\.done/)

    expect do
      described_class.record("maintenance.session.started", outcome: "maybe", maintainer_id: maintainer.id,
                             credential: { "kind" => "session" }, module_name: "session")
    end.to raise_error(ArgumentError, /maybe/)
  end

  it "keeps the attempt and its outcome on the same correlation id" do
    correlation_id = described_class.record("maintenance.maintainer.invited", outcome: "attempted",
                                            maintainer_id: maintainer.id, credential: { "kind" => "session" },
                                            module_name: "maintainer")
    described_class.record("maintenance.maintainer.invited", outcome: "ok", maintainer_id: maintainer.id,
                           credential: { "kind" => "session" }, module_name: "maintainer",
                           correlation_id: correlation_id)

    outcomes = PlatformEvent.where(name: "maintenance.maintainer.invited")
                            .select { |e| e.payload["correlation_id"] == correlation_id }
                            .map { |e| e.payload["outcome"] }

    expect(outcomes).to contain_exactly("attempted", "ok")
  end

  MaintenanceAudit::NAMES.each do |name|
    it "writes #{name} through its own dispatch branch" do
      expect do
        described_class.record(name, outcome: "ok", maintainer_id: maintainer.id,
                               credential: { "kind" => "session" }, module_name: "session")
      end.to change(PlatformEvent, :count).by(1)

      expect(PlatformEvent.order(:created_at).last.name).to eq(name)
    end
  end

  describe "immutability in the database" do
    let!(:event) do
      described_class.record("maintenance.session.started", outcome: "ok", maintainer_id: maintainer.id,
                             credential: { "kind" => "session" }, module_name: "session")
      PlatformEvent.order(:created_at).last
    end

    it "refuses UPDATE of the payload and DELETE, and still allows published_at" do
      # A exceção crua do trigger deixa a transação em estado abortado no
      # Postgres. `raise_error` já rescata a exceção dentro do bloco, então o
      # savepoint tem que envolver a AÇÃO (dentro do `expect { }`), não o
      # `expect` inteiro — senão o Rails tenta liberar o savepoint numa
      # conexão já abortada. `reload` limpa o estado sujo em memória entre
      # tentativas.
      expect {
        PlatformRecord.transaction(requires_new: true) do
          event.update!(payload: event.payload.merge("outcome" => "rejected"))
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /immutable/i)
      event.reload

      expect {
        PlatformRecord.transaction(requires_new: true) { event.destroy! }
      }.to raise_error(ActiveRecord::StatementInvalid, /immutable/i)
      event.reload

      expect {
        PlatformRecord.transaction(requires_new: true) { event.update!(published_at: Time.current) }
      }.not_to raise_error
    end

    # Minor (fix round 2): a condição não olhava a CHAVE. Reapontar o `id` é
    # reescrever a trilha de um jeito pior do que editar o payload: o evento
    # continua lá, com o conteúdo intacto, e a correlação passa a mentir.
    it "refuses moving the row to another id" do
      expect {
        PlatformRecord.transaction(requires_new: true) do
          PlatformRecord.connection.execute(
            "UPDATE platform_events SET id = gen_random_uuid() WHERE id = '#{event.id}'"
          )
        end
      }.to raise_error(ActiveRecord::StatementInvalid, /immutable/i)

      expect(PlatformEvent.find_by(id: event.id)).to be_present
    end

    it "leaves the other platform events alone" do
      Platform.audit("operator.login", operator_id: SecureRandom.uuid)
      other = PlatformEvent.order(:created_at).last

      expect { other.destroy! }.not_to raise_error
    end

    # O trigger não aparece em db/platform_schema.rb (o dump em Ruby não
    # representa trigger): um banco reconstruído por schema:load ficaria sem ele.
    it "is installed as a trigger, not only as application code" do
      installed = PlatformRecord.connection.select_value(<<~SQL.squish)
        SELECT count(*) FROM pg_trigger
        WHERE NOT tgisinternal AND tgname = 'platform_events_maintenance_immutable'
      SQL

      expect(installed.to_i).to eq(1)
    end
  end
end
