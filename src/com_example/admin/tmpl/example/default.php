<?php

defined('_JEXEC') or die;

use Joomla\CMS\HTML\HTMLHelper;
use Joomla\CMS\Version;

HTMLHelper::_('stylesheet', 'com_example/example.css', ['relative' => true]);
?>
<div class="com-example">
	<h1>com_example works</h1>
	<p>Administrator view. Edit <code>src/com_example/admin/tmpl/example/default.php</code>, run <code>make deploy</code>, refresh.</p>
	<p>Joomla <?php echo (new Version())->getShortVersion(); ?> on PHP <?php echo PHP_VERSION; ?></p>
</div>
