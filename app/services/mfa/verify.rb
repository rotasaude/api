require "rotp"

module Mfa
  module Verify
    DRIFT = 30  # segundos — tolera relógio mal sincronizado

    def self.call(user, code:)
      return false if user.otp_secret.blank? || code.blank?
      return true if totp_valid?(user, code)
      consume_recovery_code(user, code)
    end

    # Guarda própria de branco: `call` já filtrava antes de chegar aqui, mas
    # agora este método é chamado DIRETO pelo fluxo de manutenção (TOTP-only),
    # e ROTP::TOTP.new(nil) levanta.
    def self.totp_valid?(user, code)
      return false if user.otp_secret.blank? || code.blank?

      ROTP::TOTP.new(user.otp_secret).verify(code.to_s.gsub(/\s+/, ""), drift_behind: DRIFT, drift_ahead: DRIFT).present?
    end

    # I3 (fix round 2): o PASSO de tempo que o código verificou, ou nil.
    #
    # Existe só para a API de manutenção: `totp_valid?` responde sim/não, e com
    # sim/não não há como recusar a REPETIÇÃO do mesmo código — que a
    # tolerância de relógio acima mantém válido por ~90 segundos, em qualquer
    # endpoint. `Maintainer#consume_totp!` grava este número e recusa o
    # repetido. User e Operator continuam em `call`/`totp_valid?`, sem mudança
    # de comportamento: quem tem senha permanente e recovery code não ganha
    # nada com isto, e mexer ali mudaria o console e o app de cidadão.
    def self.totp_step_for(user, code)
      step_for_secret(user.otp_secret, code)
    end

    # O passo de um segredo QUALQUER — a confirmação de matrícula verifica
    # contra o segredo PENDENTE, que não está em nenhum atributo do modelo.
    def self.step_for_secret(secret, code)
      return nil if secret.blank? || code.blank?

      totp = ROTP::TOTP.new(secret)
      at = totp.verify(code.to_s.gsub(/\s+/, ""), drift_behind: DRIFT, drift_ahead: DRIFT)
      at && (at.to_i / totp.interval)
    end

    # Consome UM código de recuperação, e nunca dois ao preço de um.
    #
    # A lista é uma coluna jsonb: consumir é ler o array, tirar um item e
    # regravar o array inteiro. Sem lock, duas requisições simultâneas partem do
    # mesmo array e a segunda gravação desfaz a primeira — o código que a outra
    # acabou de consumir volta a valer, e o mesmo código aceito duas vezes rende
    # dois step-up. Por isso a remoção acontece sob lock da linha do usuário
    # (`with_lock` = transação + SELECT FOR UPDATE + reload), que é o que garante
    # que o array regravado saiu do estado ATUAL, não de um retrato velho.
    #
    # O BCrypt fica FORA do lock de propósito: comparar até dez hashes custa
    # ~3 s no custo de produção, e segurar a linha por isso bloquearia as outras
    # requisições da mesma pessoa. Fora do lock a comparação só escolhe QUAL
    # hash procurar; dentro do lock a remoção é comparação de string, e é ela
    # que decide se este código ainda valia.
    def self.consume_recovery_code(user, code)
      matched = user.otp_recovery_codes.find { |hashed| BCrypt::Password.new(hashed) == code.to_s.downcase }
      return false if matched.nil?

      consumed = false
      user.with_lock do
        remaining = user.otp_recovery_codes.dup
        consumed = !remaining.delete(matched).nil?
        user.update!(otp_recovery_codes: remaining) if consumed
      end
      consumed
    end
  end
end
