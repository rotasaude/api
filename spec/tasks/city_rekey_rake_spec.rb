require "rails_helper"
require "rake"

RSpec.describe "city:rekey and city:rotate_key rake tasks" do
  include ActiveSupport::Testing::TimeHelpers

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("city:rekey") }
  before { %w[city:rekey city:rotate_key].each { |t| Rake::Task[t].reenable } }

  let!(:city) do
    create(:city, database_url: city_database_url("rota_saude_test_city_a"), status: "suspended")
  end

  def invoke_silently(name, *args)
    original_stderr, $stderr = $stderr, StringIO.new
    Rake::Task[name].invoke(*args)
  ensure
    $stderr = original_stderr
  end

  # Não existe helper de captura nesta suíte — este é local, no mesmo estilo do
  # invoke_silently acima. Devolve o que a task escreveu em stdout.
  def capture_stdout
    original_stdout, $stdout = $stdout, StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original_stdout
  end

  # Mesmo estilo de capture_stdout acima, para o lado do abort (Kernel#abort
  # escreve a mensagem em $stderr antes de levantar SystemExit).
  def capture_stderr
    original_stderr, $stderr = $stderr, StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original_stderr
  end

  # `city` (acima) é criada JÁ suspended pela factory, sem PlatformEvent
  # "city.suspended" — por isso os exemplos de cima passam pela guarda do
  # período de quietude sem notar que ela existe. Estes simulam a suspensão
  # "de verdade" (via Platform.audit, o mesmo canal que
  # CityLifecycle::Suspend usa) para exercitar F1.
  def suspend_recently!
    Platform.audit("city.suspended", city_id: city.id)
  end

  it "refuses an unknown slug" do
    expect { invoke_silently("city:rekey", "naoexiste") }.to raise_error(SystemExit)
  end

  it "refuses a city that is not suspended" do
    city.update!(status: "active")
    expect { invoke_silently("city:rekey", city.slug) }.to raise_error(SystemExit)
  end

  it "rekeys a suspended city" do
    expect { invoke_silently("city:rekey", city.slug) }
      .to output(/\[city:rekey\] #{city.slug}/).to_stdout
  end

  # O nome do exemplo tem de ser provado: capture a saída e verifique a AUSÊNCIA
  # do material. Compare booleano (e não a string), senão um diff de falha do
  # RSpec imprime exatamente a chave que este exemplo existe para manter fora da
  # saída.
  it "does not echo key material" do
    material = city.reload.encryption_key
    out = capture_stdout { invoke_silently("city:rekey", city.slug) }

    expect(out.include?(material)).to be(false)
  end

  # Digests: `not_to eq` entre dois materiais imprimiria os dois no diff.
  it "rotate_key replaces the stored material" do
    before_digest = Digest::SHA256.hexdigest(city.reload.encryption_key)
    invoke_silently("city:rotate_key", city.slug)

    expect(Digest::SHA256.hexdigest(city.reload.encryption_key)).not_to eq(before_digest)
  end

  # Fix round 1: city:rotate_key era coberto só pelo happy-path sobre uma
  # cidade de factory vazia. Os três exemplos abaixo cobrem os ramos que nunca
  # tinham executado — em especial o de restauração, que só existe na task
  # (CityRekey não sabe nada sobre "restaurar o catálogo").

  it "city:rotate_key refuses an unknown slug" do
    expect { invoke_silently("city:rotate_key", "naoexiste") }.to raise_error(SystemExit)
  end

  # Prova algo que o exemplo equivalente de city:rekey não prova: uma rotação
  # recusada não pode ter gravado material novo no catálogo.
  it "city:rotate_key refuses a city that is not suspended, leaving the stored material untouched" do
    before_digest = Digest::SHA256.hexdigest(city.reload.encryption_key)
    city.update!(status: "active")

    expect { invoke_silently("city:rotate_key", city.slug) }.to raise_error(SystemExit)
    expect(Digest::SHA256.hexdigest(city.reload.encryption_key)).to eq(before_digest)
  end

  # O double é legítimo aqui: o objeto sob teste é o wrapper da rake task (a
  # restauração do catálogo em caso de falha), não CityRekey — que já tem seu
  # próprio spec (spec/commands/city_rekey_spec.rb) para o caminho :unreadable.
  # Assert SystemExit por si só provaria só que a task saiu; a asserção do
  # digest é o que prova que a restauração de fato devolveu `previous` ao
  # catálogo.
  it "city:rotate_key restores the previous material in the catalog when the rewrite fails" do
    before_digest = Digest::SHA256.hexdigest(city.reload.encryption_key)
    allow(CityRekey).to receive(:call).and_return(Result.fail(:unreadable, message: "linha ilegível"))

    expect { invoke_silently("city:rotate_key", city.slug) }.to raise_error(SystemExit)
    expect(Digest::SHA256.hexdigest(city.reload.encryption_key)).to eq(before_digest)
  end

  # Fix F1 (o Critical desta rodada): suspensão sozinha não basta — outros
  # processos web ainda servem a cidade como ativa, com o material antigo, por
  # até CityLifecycle::SuspensionGuard::QUIET_PERIOD depois do city.suspended
  # real. Os quatro exemplos abaixo provam a recusa enquanto isso é recente E
  # que a tarefa roda normalmente depois — sem o segundo exemplo, um bloqueio
  # PERMANENTE (nunca deixar rodar) também faria o primeiro passar, e a
  # suíte não notaria a diferença.

  it "city:rekey refuses a city suspended less than the quiet period ago" do
    suspend_recently!

    # Sem invoke_silently aqui de propósito: ele redireciona $stderr para uma
    # StringIO DESCARTADA (existe só para não poluir a saída dos exemplos de
    # happy-path acima) — usá-lo aqui devolveria "" sempre, prova nenhuma.
    out = capture_stderr { expect { Rake::Task["city:rekey"].invoke(city.slug) }.to raise_error(SystemExit) }

    expect(out).to match(/aguarde #{CityLifecycle::SuspensionGuard::QUIET_PERIOD.to_i} s/)
  end

  it "city:rekey runs once the quiet period since the real suspension has elapsed" do
    suspend_recently!

    travel(CityLifecycle::SuspensionGuard::QUIET_PERIOD + 1.second) do
      expect { invoke_silently("city:rekey", city.slug) }
        .to output(/\[city:rekey\] #{city.slug}/).to_stdout
    end
  end

  it "city:rotate_key refuses a city suspended less than the quiet period ago, leaving the stored material untouched" do
    before_digest = Digest::SHA256.hexdigest(city.reload.encryption_key)
    suspend_recently!

    out = capture_stderr { expect { Rake::Task["city:rotate_key"].invoke(city.slug) }.to raise_error(SystemExit) }

    expect(out).to match(/aguarde #{CityLifecycle::SuspensionGuard::QUIET_PERIOD.to_i} s/)
    expect(Digest::SHA256.hexdigest(city.reload.encryption_key)).to eq(before_digest)
  end

  it "city:rotate_key runs once the quiet period since the real suspension has elapsed" do
    before_digest = Digest::SHA256.hexdigest(city.reload.encryption_key)
    suspend_recently!

    travel(CityLifecycle::SuspensionGuard::QUIET_PERIOD + 1.second) do
      invoke_silently("city:rotate_key", city.slug)
    end

    expect(Digest::SHA256.hexdigest(city.reload.encryption_key)).not_to eq(before_digest)
  end

  # Fix F2 (rodada final de revisão): report_snapshots.signature deriva do
  # encryption_key da cidade, mas CityRekey::TARGETS não o cobre (não é um
  # `encrypts`). Sem city:rotate_key rodar CityReports::Resign por baixo dos
  # panos, todo link de relatório assinado ANTES da rotação vira 404 —
  # nem a chave nova bate (mudou), nem a legada global (nunca foi essa).
  # Prova por id/booleano, nunca token ou signature (ver comentário de
  # "does not echo key material" acima, mesma razão).
  describe "report link survival across city:rotate_key" do
    def snapshot_signed_with_current_key
      CityConnection.with(city) do
        pd = ProtocolDefinition.create!(
          name: "triagem-rotate", version: 1, status: "active",
          definition: { "name" => "triagem-rotate", "version" => 1, "start_step_id" => "s1",
                        "steps" => [ { "id" => "s1", "prompt" => "?", "answer_type" => "boolean",
                                       "branches" => { "true" => nil, "false" => nil } } ] }
        )
        convo = Conversation.create!(phone: "+5541988886666", state: "greeting")
        triage = Triage.create!(conversation: convo, protocol_definition: pd, protocol_name: "triagem-rotate",
                                status: "completed", tier: "alta", priority: 1,
                                completed_at: Time.current, outcome: { "trail" => [] })
        token = ReportSnapshot.mint_token
        ReportSnapshot.create!(triage: triage, protocol_definition: pd, outcome: { "tier" => "alta" },
                               payload: { "tier" => "alta" }, token: token,
                               signature: ReportSnapshot.sign(token), expires_at: 30.days.from_now)
      end
    end

    it "still resolves a token minted before the rotation" do
      snapshot = snapshot_signed_with_current_key

      invoke_silently("city:rotate_key", city.slug)

      found = CityConnection.with(city.reload) { ReportSnapshot.find_by_signed_token(snapshot.token) }
      expect(found&.id).to eq(snapshot.id)
    end

    it "reports the resign count alongside the rekey counts" do
      snapshot_signed_with_current_key

      out = capture_stdout { invoke_silently("city:rotate_key", city.slug) }

      expect(out).to match(/report_signatures=1/)
    end
  end
end
