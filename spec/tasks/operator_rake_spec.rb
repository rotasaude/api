require "rails_helper"
require "rake"

# F-06.4: o operador de plataforma não tinha como nascer fora do seed de dev.
# operator:create cria a conta, já com TOTP, e mostra senha gerada, otpauth URI
# e códigos de recuperação UMA vez, no terminal de quem rodou.
RSpec.describe "operator rake tasks" do
  before(:all) do
    Rails.application.load_tasks unless Rake::Task.task_defined?("operator:create")
  end

  def invoke(env)
    Rake::Task["operator:create"].reenable
    original_stdout, $stdout = $stdout, StringIO.new
    original_stderr, $stderr = $stderr, StringIO.new
    saved = env.keys.to_h { |k| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    Rake::Task["operator:create"].invoke
    $stdout.string
  ensure
    saved&.each { |k, v| ENV[k] = v }
    $stdout = original_stdout
    $stderr = original_stderr
  end

  it "cria o operador com TOTP ativo, mostra senha gerada, otpauth e recovery codes, e audita sem dado pessoal" do
    output = invoke("EMAIL" => "Nova.Op@RotaSaude.app", "PASSWORD" => nil)

    operator = Operator.find_by!(email_address: "nova.op@rotasaude.app")
    expect(operator).to be_mfa_enrolled
    expect(operator).to be_active

    password = output[/senha: (\S+)/, 1]
    expect(password.length).to be >= 20
    expect(operator.authenticate(password)).to be_truthy
    expect(output).to include("otpauth://totp/")
    codes = output.scan(/^\s+([a-z0-9]{10})$/).flatten
    expect(codes.size).to eq(Mfa::Enroll::RECOVERY_COUNT)
    expect(operator.otp_recovery_codes.size).to eq(Mfa::Enroll::RECOVERY_COUNT)

    event = PlatformEvent.find_by!(name: "operator.created")
    expect(event.payload).to eq("operator_id" => operator.id)
  end

  it "usa PASSWORD do ambiente quando vem e não a imprime" do
    output = invoke("EMAIL" => "com-senha@rotasaude.app", "PASSWORD" => "uma-senha-bem-longa-1")

    expect(Operator.find_by!(email_address: "com-senha@rotasaude.app").authenticate("uma-senha-bem-longa-1")).to be_truthy
    expect(output).not_to include("uma-senha-bem-longa-1")
  end

  it "recusa e-mail que já é operador, sem mexer na conta nem auditar" do
    invoke("EMAIL" => "dupla@rotasaude.app", "PASSWORD" => "uma-senha-bem-longa-1")
    digest = Operator.find_by!(email_address: "dupla@rotasaude.app").password_digest

    expect { invoke("EMAIL" => "DUPLA@rotasaude.app", "PASSWORD" => "outra-senha-longa-22") }.to raise_error(SystemExit)
    expect(Operator.find_by!(email_address: "dupla@rotasaude.app").password_digest).to eq(digest)
    expect(PlatformEvent.where(name: "operator.created").count).to eq(1)
  end

  it "recusa e-mail inválido e senha curta" do
    expect { invoke("EMAIL" => "nao-e-email", "PASSWORD" => nil) }.to raise_error(SystemExit)
    expect { invoke("EMAIL" => "curta@rotasaude.app", "PASSWORD" => "curta") }.to raise_error(SystemExit)
    expect(Operator.where(email_address: "curta@rotasaude.app")).to be_empty
  end
end
