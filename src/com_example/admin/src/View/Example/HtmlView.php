<?php

namespace Acme\Component\Example\Administrator\View\Example;

defined('_JEXEC') or die;

use Joomla\CMS\MVC\View\HtmlView as BaseHtmlView;
use Joomla\CMS\Toolbar\ToolbarHelper;

class HtmlView extends BaseHtmlView
{
    public function display($tpl = null): void
    {
        ToolbarHelper::title('Example', 'puzzle');

        parent::display($tpl);
    }
}
