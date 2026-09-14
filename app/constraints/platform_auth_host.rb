# Constraint de rota: casa requisições dirigidas a auth.*, onde mora o callback
# único do gov.br (spec banco-por-cidade §5, Plano 3B).
class PlatformAuthHost
  def self.matches?(request)
    CityCatalog.auth_host?(request.host)
  end
end
