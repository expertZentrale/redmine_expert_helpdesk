# Gemeinsame (abstrakte) Basisklasse der Plugin-Modelle.
#
# Redmine 6+ definiert `ApplicationRecord` und bindet die `acts_as_*`-DSLs dort ein;
# Redmine 5.x kennt `ApplicationRecord` nicht und bindet sie in `ActiveRecord::Base` ein.
# Daher je nach Version die passende Basis waehlen, damit die Modelle unter beiden
# Versionen `acts_as_event`, `acts_as_activity_provider`, `acts_as_positioned` usw. erhalten.
class HelpdeskApplicationRecord < (defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base)
  self.abstract_class = true
end
