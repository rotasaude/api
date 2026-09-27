# Criação de operador de plataforma (F-06.4). Fora do seed de dev, é o ÚNICO
# caminho: o primeiro operador de cada ambiente não tem quem o crie pela API.
#
#   EMAIL=fulana@rotasaude.app bin/rails operator:create
#   EMAIL=... PASSWORD=... bin/rails operator:create   # senha escolhida, não impressa
#
# Sai com TOTP ativo: a senha gerada, a otpauth URI e os códigos de recuperação
# aparecem UMA vez, neste terminal, e nunca mais (o banco guarda só digest e
# segredo cifrado). Operador sem TOTP não entra no console (403
# mfa_enrollment_required), então não existe meio-termo sem segundo fator.
#
# Auditoria na plataforma só com o id: e-mail é dado pessoal (Ruling R18).
namespace :operator do
  desc "Cria um operador de plataforma com TOTP. Uso: EMAIL=... [PASSWORD=...] bin/rails operator:create"
  task create: :environment do
    min_password = 12
    email = ENV["EMAIL"].to_s.strip.downcase
    abort "uso: EMAIL=... [PASSWORD=...] bin/rails operator:create" if email.blank?
    abort "[operator:create] e-mail inválido" unless email.match?(URI::MailTo::EMAIL_REGEXP)
    abort "[operator:create] #{email} já é operador" if Operator.exists?(email_address: email)

    chosen = ENV["PASSWORD"].presence
    abort "[operator:create] PASSWORD precisa de pelo menos #{min_password} caracteres" if chosen && chosen.length < min_password
    password = chosen || SecureRandom.base58(24)

    operator = Operator.new(email_address: email, password: password)
    enrollment = nil
    PlatformRecord.transaction do
      operator.save!
      enrollment = Mfa::Enroll.call(operator)
      operator.update!(otp_enabled: true)
      Platform.audit("operator.created", operator_id: operator.id)
    end

    puts "[operator:create] operador #{email} criado (mostrado só agora — guarde no cofre)"
    puts "[operator:create] senha: #{password}" unless chosen
    puts "[operator:create] autenticador: #{enrollment[:otpauth_uri]}"
    puts "[operator:create] códigos de recuperação (uso único):"
    enrollment[:recovery_codes].each { |code| puts "  #{code}" }
  end
end
