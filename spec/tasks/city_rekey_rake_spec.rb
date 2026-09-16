require "rails_helper"
require "rake"

RSpec.describe "city:rekey and city:rotate_key rake tasks" do
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
end
