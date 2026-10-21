# Papéis do faturamento (ADR 0039; spec §3): o faturista opera; o admin
# municipal lê. O profissional grava no próprio contexto (vínculo/autoria).
module Billing
  module Access
    module_function

    def clerk?(user) = user.has_role?("billing_clerk")
    def admin?(user) = user.has_role?("municipal_admin")
    def reader?(user) = clerk?(user) || admin?(user)
  end
end
