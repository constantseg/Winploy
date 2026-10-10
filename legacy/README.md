# Version historique

`Winploy-GUI.ps1` est WinPloy 1.0.0 : un script PowerShell + WinForms unique, point de départ du projet.

**Il n'est plus maintenu.** La version utilisée est l'application C# / WPF à la racine du dépôt — voir le
[README](../README.md). Le script est conservé ici pour référence : il documente le comportement d'origine
et sert de point de comparaison pour la conversion décrite dans
[docs/PLAN-CONVERSION.md](../docs/PLAN-CONVERSION.md).

Il reste fonctionnel sur un poste d'administration disposant des RSAT (module `ActiveDirectory`), et lit le
même format de catalogue que la version 2.0 : les deux peuvent cohabiter pendant une transition.
