<?php

defined('_JEXEC') or die;

use Joomla\CMS\HTML\HTMLHelper;

HTMLHelper::_('stylesheet', 'com_example/example.css', ['relative' => true]);
?>
<div class="com-example">
	<h1>com_example works</h1>
	<p>Site view, reached at <code>/index.php?option=com_example</code>.</p>
</div>
