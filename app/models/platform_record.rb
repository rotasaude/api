# Base das tabelas do banco de PLATAFORMA (catálogo de cidades, roteamento,
# contas de operador). Conexão fixa — a plataforma não é resolvida por host.
#
# INVARIANTE: nenhuma tabela sob PlatformRecord guarda dado de cidadão.
# Ver docs/superpowers/specs/2026-09-12-banco-por-cidade-design.md
class PlatformRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :platform, reading: :platform }
end
