require "rails_helper"

# Módulo 04, critério de fechamento — "snapshot imutável" (ADR 0010: o
# ReportSnapshot é prova, não interpretação atualizada). O trigger de
# db/city_triggers.sql fecha o caminho que o modelo não fecha: update_all,
# update_columns, um psql com o papel de runtime. Continua permitido:
#   - signature: CityReports::Resign reescreve com a chave da cidade (Plano 8,
#     city:rotate_key);
#   - expires_at (+ updated_at): expirar o token é o jeito oficial de
#     "corrigir" um relatório (ADR 0010, Invariantes) — gera-se outro;
#   - DELETE: PurgeExpiredReportsJob apaga expirados.
# Como em db/city_triggers.sql, isto NÃO defende contra o DONO da tabela.
RSpec.describe "Invariante: ReportSnapshot imutável (ADR 0010)" do
  before { Current.city = TEST_CITY_A }
  after { Current.reset }

  def make_protocol(version, status: "active")
    ProtocolDefinition.create!(
      name: "imutavel", version: version, status: status,
      definition: { "name" => "imutavel", "version" => version, "start_step_id" => "s1",
                    "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                                   "branches" => { "true" => nil, "false" => nil } } ] }
    )
  end

  def make_triage(protocol)
    convo = Conversation.create!(phone: "+55419#{rand(10_000_000..99_999_999)}", state: "greeting")
    Triage.create!(conversation: convo, protocol_definition: protocol, protocol_name: "imutavel",
                   status: "completed", tier: "alta", priority: 1, completed_at: Time.current,
                   outcome: { "trail" => [] })
  end

  let!(:protocol) { make_protocol(1) }
  let!(:snapshot) do
    token = ReportSnapshot.mint_token
    ReportSnapshot.create!(triage: make_triage(protocol), protocol_definition: protocol,
                           outcome: { "tier" => "alta" }, payload: { "tier" => "alta", "recommendation" => "UPA" },
                           token: token, signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)
  end
  # Alvos válidos de FK: a recusa tem de vir do trigger, não da constraint.
  let!(:other_protocol) { make_protocol(2, status: "published") }
  let!(:other_triage) { make_triage(other_protocol) }

  # Savepoint na conexão da cidade (ver spec/models/protocol_append_only_spec.rb):
  # cada recusa aborta a transação; o savepoint deixa a próxima tentativa viva.
  def attempt(&block) = ReportSnapshot.transaction(requires_new: true, &block)

  def scope = ReportSnapshot.where(id: snapshot.id)

  frozen = {
    "payload" => -> { { payload: { "tier" => "baixa" } } },
    "outcome" => -> { { outcome: { "tier" => "baixa" } } },
    "token" => -> { { token: ReportSnapshot.mint_token } },
    "triage_id" => -> { { triage_id: other_triage.id } },
    "protocol_definition_id" => -> { { protocol_definition_id: other_protocol.id } },
    "created_at" => -> { { created_at: 1.year.ago } }
  }

  frozen.each do |column, change|
    it "o banco recusa UPDATE de #{column}, mesmo por update_all" do
      attrs = instance_exec(&change)
      expect { attempt { scope.update_all(attrs) } }
        .to raise_error(ActiveRecord::StatementInvalid, /report_snapshots is immutable/)
    end
  end

  it "o banco recusa UPDATE de payload feito pelo modelo" do
    expect { attempt { snapshot.update!(payload: { "tier" => "baixa" }) } }
      .to raise_error(ActiveRecord::StatementInvalid, /report_snapshots is immutable/)
    expect(snapshot.reload.payload).to eq("tier" => "alta", "recommendation" => "UPA")
  end

  it "permite reassinar (signature), como CityReports::Resign faz" do
    expect { snapshot.update_columns(signature: "nova-assinatura") }.not_to raise_error
    expect(snapshot.reload.signature).to eq("nova-assinatura")
  end

  it "permite expirar o token (expires_at, com updated_at)" do
    expect { snapshot.update!(expires_at: 1.minute.ago) }.not_to raise_error
    expect(snapshot.reload.expires_at).to be < Time.current
  end

  it "permite DELETE (purga de expirados)" do
    expect { scope.delete_all }.to change(ReportSnapshot, :count).by(-1)
  end
end
